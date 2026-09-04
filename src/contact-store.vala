public class Mail.ContactHit : Object {
    public string name { get; set; default = ""; }
    public string email { get; set; default = ""; }
    public bool from_book { get; set; }
    public int64 last_used { get; set; }
    public int uses { get; set; }

    public Recipient to_recipient () {
        return new Recipient () {
            name = this.name,
            email = this.email,
        };
    }
}

public class Mail.ContactStore : Object {
    private E.SourceRegistry? registry;
    private GenericArray<E.BookClient> books = new GenericArray<E.BookClient> ();
    private bool books_ready;
    private bool books_loading;
    private HashTable<string, Collected> collected;
    private uint save_source;

    private class Collected {
        public string email = "";
        public string name = "";
        public int64 last_used;
        public int uses;
    }

    public ContactStore () {
        this.collected = new HashTable<string, Collected> (str_hash, str_equal);
        load_collected ();
    }

    public void bind_registry (E.SourceRegistry? registry) {
        this.registry = registry;
        this.books = new GenericArray<E.BookClient> ();
        this.books_ready = false;
        this.books_loading = false;
        warm ();
    }

    public void warm () {
        if (this.registry != null)
            ensure_books.begin (null);
    }

    public GenericArray<ContactHit> search_collected (string raw, uint limit) {
        var needle = sanitize_query (raw);
        var hits = new GenericArray<ContactHit> ();
        var seen = new HashTable<string, uint8> (str_hash, str_equal);
        add_collected (hits, seen, needle, limit);
        sort_hits (hits, needle);
        return hits;
    }

    public async GenericArray<ContactHit> search (
        string raw,
        uint limit,
        Cancellable? cancellable = null,
        bool any_field = true
    ) {
        var needle = sanitize_query (raw);
        var hits = new GenericArray<ContactHit> ();
        var seen = new HashTable<string, uint8> (str_hash, str_equal);
        add_collected (hits, seen, needle, limit);

        if (needle.length == 0) {
            sort_hits (hits, needle);
            return hits;
        }

        yield ensure_books (cancellable);
        if (cancellable != null && cancellable.is_cancelled ())
            return hits;

        var sexp = book_sexp (needle, any_field);
        for (uint i = 0; i < this.books.length; i++) {
            if (cancellable != null && cancellable.is_cancelled ())
                break;
            if (hits.length >= limit)
                break;
            try {
                SList<E.Contact>? listed = null;
                yield this.books[i].get_contacts (sexp, cancellable, out listed);
                if (listed == null)
                    continue;
                foreach (var contact in listed) {
                    if (contact != null)
                        add_book_contact (hits, seen, contact, needle, limit);
                }
            } catch (Error e) {
                if (e is IOError.CANCELLED)
                    break;
                debug ("Address book search: %s", e.message);
            }
            Idle.add (search.callback);
            yield;
        }

        sort_hits (hits, needle);
        if (hits.length <= limit)
            return hits;

        var trimmed = new GenericArray<ContactHit> ();
        for (uint i = 0; i < limit; i++)
            trimmed.add (hits[i]);
        return trimmed;
    }

    public async bool has_book_email (string email, Cancellable? cancellable = null) {
        var needle = Utils.normalize_email (email);
        if (needle == null)
            return false;

        yield ensure_books (cancellable);
        if (cancellable != null && cancellable.is_cancelled ())
            return false;

        var escaped = needle.replace ("\\", "\\\\").replace ("\"", "\\\"");
        var sexp = "(is \"email\" \"%s\")".printf (escaped);
        for (uint i = 0; i < this.books.length; i++) {
            if (cancellable != null && cancellable.is_cancelled ())
                return false;
            try {
                SList<E.Contact>? listed = null;
                yield this.books[i].get_contacts (sexp, cancellable, out listed);
                if (listed == null)
                    continue;
                foreach (var contact in listed) {
                    if (contact != null && contact_has_email (contact, needle))
                        return true;
                }
            } catch (Error e) {
                if (e is IOError.CANCELLED)
                    return false;
                debug ("Address book lookup: %s", e.message);
            }
        }
        return false;
    }

    private static void sort_hits (GenericArray<ContactHit> hits, string needle) {
        for (uint i = 1; i < hits.length; i++) {
            var current = hits[i];
            uint j = i;
            while (j > 0 && compare_hits (hits[j - 1], current, needle) > 0) {
                hits[j] = hits[j - 1];
                j--;
            }
            hits[j] = current;
        }
    }

    public void remember_recipients (GenericArray<Recipient> recipients) {
        var now = new DateTime.now_utc ().to_unix ();
        var changed = false;
        for (uint i = 0; i < recipients.length; i++) {
            var email = Utils.sanitize_recipient_text (recipients[i].email).down ();
            if (email.length == 0 || !email.contains ("@"))
                continue;
            var name = Utils.sanitize_recipient_text (recipients[i].name);
            var entry = this.collected.get (email);
            if (entry == null) {
                entry = new Collected ();
                entry.email = email;
                this.collected.set (email, entry);
            }
            if (name.length > 0 && (entry.name.length == 0 || entry.name.contains ("@")))
                entry.name = name;
            else if (name.length > 0 && entry.name != name)
                entry.name = name;
            entry.last_used = now;
            entry.uses++;
            changed = true;
        }
        if (changed)
            queue_save ();
    }

    private async void ensure_books (Cancellable? cancellable) {
        if (this.books_ready || this.registry == null)
            return;

        while (this.books_loading) {
            Timeout.add (50, ensure_books.callback);
            yield;
        }
        if (this.books_ready)
            return;

        this.books_loading = true;
        try {
            foreach (var source in this.registry.list_enabled (E.SOURCE_EXTENSION_ADDRESS_BOOK)) {
                if (cancellable != null && cancellable.is_cancelled ())
                    break;
                if (source_is_directory (source))
                    continue;
                try {
                    var client = yield E.BookClient.connect (source, 3, cancellable);
                    this.books.add (client);
                } catch (Error e) {
                    if (e is IOError.CANCELLED)
                        break;
                    debug ("Could not open address book “%s”: %s", source.dup_display_name (), e.message);
                }
                Idle.add (ensure_books.callback);
                yield;
            }
            this.books_ready = true;
        } finally {
            this.books_loading = false;
        }
    }

    private static bool source_is_directory (E.Source source) {
        var name = (source.dup_display_name () ?? "").down ();
        var uid = source.get_uid ().down ();
        return name.contains ("organizational")
            || name.contains ("global address")
            || name.contains ("gal")
            || uid.contains ("organizational")
            || uid.contains ("gal");
    }

    private static string book_sexp (string needle, bool any_field) {
        var escaped = needle.replace ("\\", "\\\\").replace ("\"", "\\\"");
        if (any_field)
            return "(contains \"x-evolution-any-field\" \"%s\")".printf (escaped);
        return "(or (contains \"full_name\" \"%s\") (contains \"email\" \"%s\") (contains \"nickname\" \"%s\") (contains \"file_as\" \"%s\"))".printf (
            escaped, escaped, escaped, escaped
        );
    }

    private void add_collected (
        GenericArray<ContactHit> hits,
        HashTable<string, uint8> seen,
        string needle,
        uint limit
    ) {
        this.collected.foreach ((key, entry) => {
            if (hits.length >= limit)
                return;
            if (seen.contains (key))
                return;
            if (needle.length > 0 && !matches (entry.name, entry.email, needle))
                return;
            seen.set (key, 1);
            hits.add (new ContactHit () {
                name = entry.name ?? "",
                email = entry.email ?? "",
                from_book = false,
                last_used = entry.last_used,
                uses = entry.uses,
            });
        });
    }

    private static bool contact_has_email (E.Contact contact, string needle) {
        string?[] emails = {
            contact.email_1,
            contact.email_2,
            contact.email_3,
            contact.email_4,
        };
        for (uint i = 0; i < emails.length; i++) {
            if (Utils.emails_equal (emails[i], needle))
                return true;
        }
        return false;
    }

    private static void add_book_contact (
        GenericArray<ContactHit> hits,
        HashTable<string, uint8> seen,
        E.Contact contact,
        string needle,
        uint limit
    ) {
        var name = display_name (contact);
        string?[] emails = {
            contact.email_1,
            contact.email_2,
            contact.email_3,
            contact.email_4,
        };
        for (uint i = 0; i < emails.length; i++) {
            if (hits.length >= limit)
                return;
            var email = Utils.sanitize_recipient_text (emails[i]).down ();
            if (email.length == 0 || !email.contains ("@") || seen.contains (email))
                continue;
            if (needle.length > 0 && !matches (name, email, needle))
                continue;
            seen.set (email, 1);
            hits.add (new ContactHit () {
                name = name,
                email = email,
                from_book = true,
            });
        }
    }

    private static string display_name (E.Contact contact) {
        var full = Utils.sanitize_recipient_text (contact.full_name);
        if (full.length > 0)
            return full;
        var file_as = Utils.sanitize_recipient_text (contact.file_as);
        if (file_as.length > 0)
            return file_as;
        var given = Utils.sanitize_recipient_text (contact.given_name);
        var family = Utils.sanitize_recipient_text (contact.family_name);
        if (given.length > 0 && family.length > 0)
            return "%s %s".printf (given, family);
        if (given.length > 0)
            return given;
        return family;
    }

    private static bool matches (string? name, string? email, string needle) {
        var hay_name = name ?? "";
        var hay_email = email ?? "";
        return hay_name.down ().contains (needle) || hay_email.contains (needle);
    }

    private static int compare_hits (ContactHit a, ContactHit b, string needle) {
        int sa = score (a, needle);
        int sb = score (b, needle);
        if (sa != sb)
            return sb - sa;
        if (a.last_used != b.last_used)
            return a.last_used > b.last_used ? -1 : 1;
        return a.name.collate (b.name);
    }

    private static int score (ContactHit hit, string needle) {
        var points = hit.from_book ? 50 : 0;
        points += int.min (hit.uses, 20);
        if (needle.length == 0)
            return points + (hit.last_used > 0 ? 20 : 0);

        var name = hit.name.down ();
        var email = hit.email.down ();
        if (email.has_prefix (needle))
            return 400 + points;
        if (name.has_prefix (needle))
            return 300 + points;
        if (email.contains (needle))
            return 200 + points;
        if (name.contains (needle))
            return 100 + points;
        return points;
    }

    private static string sanitize_query (string raw) {
        var builder = new StringBuilder ();
        unichar c;
        int index = 0;
        while (raw.get_next_char (ref index, out c)) {
            if (c == '"' || c == '\\' || c == '(' || c == ')')
                continue;
            builder.append_unichar (c);
        }
        return builder.str.strip ().down ();
    }

    private static string collected_path () {
        return Path.build_filename (Environment.get_user_data_dir (), "letter", "collected-addresses.tsv");
    }

    private void load_collected () {
        var path = collected_path ();
        string contents;
        try {
            FileUtils.get_contents (path, out contents);
        } catch (Error e) {
            return;
        }

        foreach (var line in contents.split ("\n")) {
            if (line.length == 0 || line.has_prefix ("#"))
                continue;
            var parts = line.split ("\t", 4);
            if (parts.length < 1 || parts[0].length == 0 || !parts[0].contains ("@"))
                continue;
            var entry = new Collected ();
            entry.email = parts[0].down ();
            entry.name = parts.length > 1 ? unescape_field (parts[1]) : "";
            entry.last_used = parts.length > 2 ? int64.parse (parts[2]) : 0;
            entry.uses = parts.length > 3 ? int.parse (parts[3]) : 1;
            this.collected.set (entry.email, entry);
        }
    }

    private void queue_save () {
        if (this.save_source != 0)
            return;
        this.save_source = Timeout.add (400, () => {
            this.save_source = 0;
            save_collected ();
            return Source.REMOVE;
        });
    }

    private void save_collected () {
        var dir = Path.get_dirname (collected_path ());
        try {
            File.new_for_path (dir).make_directory_with_parents ();
        } catch (Error e) {
            if (!(e is IOError.EXISTS))
                warning ("Could not create address cache: %s", e.message);
        }

        var builder = new StringBuilder ("# letter collected addresses\n");
        this.collected.foreach ((key, entry) => {
            builder.append (entry.email);
            builder.append_c ('\t');
            builder.append (escape_field (entry.name));
            builder.append_c ('\t');
            builder.append (entry.last_used.to_string ());
            builder.append_c ('\t');
            builder.append (entry.uses.to_string ());
            builder.append_c ('\n');
        });
        try {
            FileUtils.set_contents (collected_path (), builder.str);
        } catch (Error e) {
            warning ("Could not save collected addresses: %s", e.message);
        }
    }

    private static string escape_field (string? raw) {
        if (raw == null || raw.length == 0)
            return "";
        return raw.replace ("\\", "\\\\").replace ("\t", "\\t").replace ("\n", "\\n");
    }

    private static string unescape_field (string raw) {
        var builder = new StringBuilder ();
        var escaped = false;
        unichar c;
        int index = 0;
        while (raw.get_next_char (ref index, out c)) {
            if (!escaped && c == '\\') {
                escaped = true;
                continue;
            }
            if (escaped) {
                if (c == 't')
                    builder.append_c ('\t');
                else if (c == 'n')
                    builder.append_c ('\n');
                else
                    builder.append_unichar (c);
                escaped = false;
                continue;
            }
            builder.append_unichar (c);
        }
        return builder.str;
    }
}
