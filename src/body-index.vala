/* On-disk plain-text index for message bodies.
 *
 * Search used to re-parse the cached MIME of every candidate on every query,
 * which cost seconds per folder. The text of a body never changes, so it is
 * extracted once (background job) and appended here as folded plain text.
 * A query then streams a few MB of text instead of parsing thousands of MIME
 * trees.
 *
 * This is a cache, not a database: it is append-only, tolerates stale entries
 * (resolution against Letter headers drops them), and can be deleted at any
 * time — the background job refills it. It only ever holds bodies Camel
 * already has on disk, so it stays inside the prefetch window.
 *
 * Format: "letter-bodytext-v1" magic line, then one "uid\ttext" line per
 * message, with backslash / tab / newline escaped.
 */
public class Mail.BodyTextIndex : Object {
    /* Plenty for a search hit; keeps a big folder's index in the low MBs. */
    private const size_t MAX_TEXT_CHARS = 8192;
    private const string MAGIC = "letter-bodytext-v1";

    /* folder key → uids already written, so the background job can skip them
     * without re-reading the file for every message. */
    private HashTable<string, HashTable<string, uint8>> known;

    public BodyTextIndex () {
        this.known = new HashTable<string, HashTable<string, uint8>> (str_hash, str_equal);
    }

    public static string cache_dir () {
        return Path.build_filename (Environment.get_user_cache_dir (), "letter", "body-text");
    }

    public static string index_file (string account_uid, string folder_full_name) {
        var account_safe = Checksum.compute_for_string (ChecksumType.SHA256, account_uid);
        var folder_safe = Checksum.compute_for_string (ChecksumType.SHA256, folder_full_name);
        return Path.build_filename (cache_dir (), account_safe, folder_safe);
    }

    public static void delete_for_account (string account_uid) {
        var account_safe = Checksum.compute_for_string (ChecksumType.SHA256, account_uid);
        var root = cache_dir ();
        var dir_path = Path.build_filename (root, account_safe);
        if (!dir_path.has_prefix (root + Path.DIR_SEPARATOR_S))
            return;
        try {
            var dir = Dir.open (dir_path, 0);
            string? name;
            while ((name = dir.read_name ()) != null)
                FileUtils.unlink (Path.build_filename (dir_path, name));
            DirUtils.remove (dir_path);
        } catch (Error e) {
            debug ("Could not delete body text index: %s", e.message);
        }
    }

    private static string folder_key (string account_uid, string folder_full_name) {
        return "%s\n%s".printf (account_uid, folder_full_name);
    }

    /* Which uids are already indexed. Loaded once per folder per session. */
    public unowned HashTable<string, uint8> indexed_uids (
        string account_uid,
        string folder_full_name
    ) {
        var key = folder_key (account_uid, folder_full_name);
        unowned HashTable<string, uint8>? cached = this.known.get (key);
        if (cached != null)
            return cached;

        var uids = new HashTable<string, uint8> (str_hash, str_equal);
        var path = index_file (account_uid, folder_full_name);
        if (FileUtils.test (path, FileTest.IS_REGULAR)) {
            try {
                var input = new DataInputStream (File.new_for_path (path).read (null));
                var first = input.read_line (null);
                if (first == MAGIC) {
                    string? line;
                    while ((line = input.read_line (null)) != null) {
                        var tab = line.index_of_char ('\t');
                        if (tab > 0)
                            uids.set (line.substring (0, tab), 1);
                    }
                }
            } catch (Error e) {
                debug ("Body text index read %s: %s", path, e.message);
            }
        }

        this.known.set (key, uids);
        return this.known.get (key);
    }

    public bool has (string account_uid, string folder_full_name, string uid) {
        return indexed_uids (account_uid, folder_full_name).contains (uid);
    }

    public void add (
        string account_uid,
        string folder_full_name,
        string uid,
        string? plain_text
    ) {
        var uids = indexed_uids (account_uid, folder_full_name);
        if (uids.contains (uid))
            return;

        var path = index_file (account_uid, folder_full_name);
        if (DirUtils.create_with_parents (Path.get_dirname (path), 0700) != 0
            && !FileUtils.test (Path.get_dirname (path), FileTest.IS_DIR)) {
            return;
        }

        var fresh = !FileUtils.test (path, FileTest.IS_REGULAR);
        var line = new StringBuilder ();
        if (fresh) {
            line.append (MAGIC);
            line.append_c ('\n');
        }
        line.append (uid);
        line.append_c ('\t');
        append_escaped (line, fold_text (plain_text));
        line.append_c ('\n');

        try {
            var stream = File.new_for_path (path).append_to (FileCreateFlags.PRIVATE, null);
            stream.write_all (line.str.data, null, null);
            stream.close (null);
            uids.set (uid, 1);
        } catch (Error e) {
            debug ("Body text index write %s: %s", path, e.message);
        }
    }

    /* Drop the whole folder index; cheaper and simpler than rewriting it when
     * a folder is emptied or resynced from scratch. */
    public void forget_folder (string account_uid, string folder_full_name) {
        this.known.remove (folder_key (account_uid, folder_full_name));
        FileUtils.unlink (index_file (account_uid, folder_full_name));
    }

    public delegate bool BodyTextVisitor (string uid, string text);

    /* Streams the folder index. The visitor returns false to stop early.
     * Reading line by line keeps peak memory at one message, not one folder. */
    public static void scan (
        string account_uid,
        string folder_full_name,
        BodyTextVisitor visitor
    ) {
        var path = index_file (account_uid, folder_full_name);
        if (!FileUtils.test (path, FileTest.IS_REGULAR))
            return;

        try {
            var input = new DataInputStream (File.new_for_path (path).read (null));
            var first = input.read_line (null);
            if (first != MAGIC)
                return;
            string? line;
            while ((line = input.read_line (null)) != null) {
                var tab = line.index_of_char ('\t');
                if (tab <= 0)
                    continue;
                var uid = line.substring (0, tab);
                var text = unescape (line.substring (tab + 1));
                if (!visitor (uid, text))
                    return;
            }
        } catch (Error e) {
            debug ("Body text index scan %s: %s", path, e.message);
        }
    }

    /* Same as scan, but yields to the main loop so search does not freeze UI. */
    public static async void scan_async (
        string account_uid,
        string folder_full_name,
        BodyTextVisitor visitor,
        uint yield_every = 64
    ) {
        var path = index_file (account_uid, folder_full_name);
        if (!FileUtils.test (path, FileTest.IS_REGULAR))
            return;

        try {
            var input = new DataInputStream (File.new_for_path (path).read (null));
            var first = input.read_line (null);
            if (first != MAGIC)
                return;
            string? line;
            uint n = 0;
            while ((line = input.read_line (null)) != null) {
                var tab = line.index_of_char ('\t');
                if (tab <= 0)
                    continue;
                var uid = line.substring (0, tab);
                var text = unescape (line.substring (tab + 1));
                if (!visitor (uid, text))
                    return;
                n++;
                if (yield_every > 0 && n % yield_every == 0) {
                    Idle.add (scan_async.callback);
                    yield;
                }
            }
        } catch (Error e) {
            debug ("Body text index scan %s: %s", path, e.message);
        }
    }

    private static string fold_text (string? raw) {
        if (raw == null || raw.length == 0)
            return "";
        var text = raw;
        if (text.length > (int) MAX_TEXT_CHARS) {
            var cut = text.substring (0, (int) MAX_TEXT_CHARS);
            /* substring can split a UTF-8 sequence; keep the valid prefix. */
            text = cut.make_valid ();
        }
        return text.casefold ();
    }

    private static void append_escaped (StringBuilder builder, string text) {
        for (int i = 0; i < text.length; i++) {
            var c = text[i];
            switch (c) {
                case '\\':
                    builder.append ("\\\\");
                    break;
                case '\t':
                    builder.append ("\\t");
                    break;
                case '\n':
                    builder.append ("\\n");
                    break;
                case '\r':
                    break;
                default:
                    builder.append_c (c);
                    break;
            }
        }
    }

    private static string unescape (string text) {
        if (text.index_of_char ('\\') < 0)
            return text;
        var builder = new StringBuilder ();
        for (int i = 0; i < text.length; i++) {
            if (text[i] != '\\') {
                builder.append_c (text[i]);
                continue;
            }
            i++;
            if (i >= text.length)
                break;
            switch (text[i]) {
                case 't':
                    builder.append_c ('\t');
                    break;
                case 'n':
                    builder.append_c ('\n');
                    break;
                default:
                    builder.append_c (text[i]);
                    break;
            }
        }
        return builder.str;
    }
}
