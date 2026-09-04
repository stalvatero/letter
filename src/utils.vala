namespace Mail.Utils {
    public static string app_display_name () {
        if (Config.PROFILE == "development")
            return _("Letter (Development)");
        return _("Letter");
    }

    public static void migrate_legacy_app_dirs () {
        migrate_dir (
            Path.build_filename (Environment.get_user_data_dir (), "gnome-mail"),
            Path.build_filename (Environment.get_user_data_dir (), "letter")
        );
        migrate_dir (
            Path.build_filename (Environment.get_user_cache_dir (), "gnome-mail"),
            Path.build_filename (Environment.get_user_cache_dir (), "letter")
        );
    }

    private static void migrate_dir (string old_path, string new_path) {
        var old_file = File.new_for_path (old_path);
        var new_file = File.new_for_path (new_path);
        if (!old_file.query_exists () || new_file.query_exists ())
            return;
        try {
            old_file.move (new_file, FileCopyFlags.NONE);
            message ("Moved %s → %s", old_path, new_path);
        } catch (Error e) {
            warning ("Could not migrate %s to %s: %s", old_path, new_path, e.message);
        }
    }

    public static void sync_log (string text) {
        var stamp = new DateTime.now_local ().format ("%H:%M:%S");
        message ("[letter-sync %s] %s", stamp, text);
    }

    public static int64 sync_tick () {
        return get_monotonic_time ();
    }

    public static string sync_ms (int64 start) {
        return "%.0f ms".printf ((get_monotonic_time () - start) / 1000.0);
    }

    public static bool focus_is_text_input (Gtk.Window window) {
        var widget = window.get_focus ();
        while (widget != null) {
            if (widget is Gtk.TextView || widget is Gtk.Text || widget is Gtk.Editable)
                return true;
            widget = widget.get_parent ();
        }
        return false;
    }

    public static bool handle_mail_letter_shortcut (Gtk.Widget widget, uint keyval, Gdk.ModifierType state) {
        var window = widget.get_root () as Gtk.Window;
        if (window != null && focus_is_text_input (window))
            return false;

        var mods = state & Gtk.accelerator_get_default_mod_mask ();
        var key = Gdk.keyval_to_lower (keyval);
        string? action = null;
        if (key == Gdk.Key.a && mods == 0)
            action = "win.archive";
        else if (key == Gdk.Key.r && mods == 0)
            action = "win.reply";
        else if (key == Gdk.Key.r && mods == Gdk.ModifierType.SHIFT_MASK)
            action = "win.reply-all";
        else if (key == Gdk.Key.f && mods == 0)
            action = "win.forward";
        if (action == null)
            return false;

        widget.activate_action (action, null);
        return true;
    }

    public static bool handle_reader_zoom_shortcut (Gtk.Widget widget, uint keyval, Gdk.ModifierType state) {
        var mods = state & Gtk.accelerator_get_default_mod_mask ();
        if ((mods & Gdk.ModifierType.CONTROL_MASK) == 0)
            return false;
        if ((mods & (Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK)) != 0)
            return false;

        var key = Gdk.keyval_to_lower (keyval);
        string? action = null;
        if (key == Gdk.Key.plus || key == Gdk.Key.equal || key == Gdk.Key.KP_Add)
            action = "win.zoom-in";
        else if (key == Gdk.Key.minus || key == Gdk.Key.KP_Subtract)
            action = "win.zoom-out";
        else if (key == Gdk.Key.@0 || key == Gdk.Key.KP_0)
            action = "win.zoom-reset";
        if (action == null)
            return false;

        widget.activate_action (action, null);
        return true;
    }

    public static void add_mail_letter_shortcuts (Gtk.Widget widget) {
        var keys = new Gtk.EventControllerKey ();
        keys.set_propagation_phase (Gtk.PropagationPhase.CAPTURE);
        keys.key_pressed.connect ((keyval, keycode, state) => {
            return handle_mail_letter_shortcut (widget, keyval, state)
                || handle_reader_zoom_shortcut (widget, keyval, state);
        });
        widget.add_controller (keys);
    }

    public static void open_online_accounts () {
        open_online_account (null);
    }

    public static void open_online_account (string? account_id) {
        string[] cmd;
        if (account_id != null && account_id.length > 0)
            cmd = { "gnome-control-center", "online-accounts", account_id };
        else
            cmd = { "gnome-control-center", "online-accounts" };
        try {
            Process.spawn_async (null, cmd, null, SpawnFlags.SEARCH_PATH, null, null);
        } catch (Error e) {
            warning ("Could not open GNOME Settings: %s", e.message);
        }
    }

    public static File ensure_attachment_file (Attachment attachment) throws Error {
        if (attachment.file != null && attachment.file.query_exists ())
            return attachment.file;
        if (attachment.data == null || attachment.data.get_size () == 0) {
            throw new IOError.NOT_FOUND (
                _("The attachment “%s” is empty.").printf (attachment.filename)
            );
        }

        var dir = File.new_for_path (Environment.get_tmp_dir ()).get_child (
            "mail-attach-%u".printf (Random.next_int ())
        );
        dir.make_directory ();
        var dest = dir.get_child (attachment.save_filename);
        write_attachment (attachment, dest);
        attachment.file = dest;
        return dest;
    }

    public static File download_folder () {
        var settings = new Settings (Config.APP_ID);
        var saved = settings.get_string ("last-download-folder");
        if (saved.length > 0) {
            var folder = saved.has_prefix ("/")
                ? File.new_for_path (saved)
                : File.new_for_uri (saved);
            if (folder.query_exists ())
                return folder;
        }

        var special = Environment.get_user_special_dir (UserDirectory.DOWNLOAD);
        if (special != null && special.length > 0) {
            var folder = File.new_for_path (special);
            if (folder.query_exists ())
                return folder;
        }

        return File.new_for_path (Environment.get_home_dir ());
    }

    public static void remember_download_folder (File file) {
        var folder = file.query_file_type (FileQueryInfoFlags.NONE, null) == FileType.DIRECTORY
            ? file
            : file.get_parent ();
        if (folder == null)
            return;
        var settings = new Settings (Config.APP_ID);
        settings.set_string ("last-download-folder", folder.get_uri ());
    }

    public static async void save_attachment (Attachment attachment, Gtk.Window? parent) throws Error {
        var dialog = new Gtk.FileDialog () {
            title = _("Save Attachment"),
            initial_name = attachment.save_filename,
            initial_folder = download_folder (),
        };
        var file = yield dialog.save (parent, null);
        write_attachment (attachment, file);
        remember_download_folder (file);
    }

    public static async void save_attachments (GenericArray<Attachment> attachments, Gtk.Window? parent) throws Error {
        if (attachments.length == 1) {
            yield save_attachment (attachments[0], parent);
            return;
        }

        var dialog = new Gtk.FileDialog () {
            title = _("Save Attachments"),
            accept_label = _("Save"),
            initial_folder = download_folder (),
        };
        var folder = yield dialog.select_folder (parent, null);
        for (uint i = 0; i < attachments.length; i++)
            write_attachment (attachments[i], unique_in_folder (folder, attachments[i].save_filename));
        remember_download_folder (folder);
    }

    public static void write_attachment (Attachment attachment, File dest) throws Error {
        string? etag;
        if (attachment.data != null && attachment.data.get_size () > 0) {
            dest.replace_contents (
                attachment.data.get_data (),
                null,
                false,
                FileCreateFlags.REPLACE_DESTINATION,
                out etag
            );
            return;
        }

        var source = ensure_attachment_file (attachment);
        source.copy (dest, FileCopyFlags.OVERWRITE);
    }

    private static File unique_in_folder (File folder, string filename) {
        var name = Path.get_basename (filename);
        if (name.length == 0)
            name = "attachment";
        var dest = folder.get_child (name);
        if (!dest.query_exists ())
            return dest;

        var stem = name;
        var ext = "";
        var dot = name.last_index_of_char ('.');
        if (dot > 0) {
            stem = name.substring (0, dot);
            ext = name.substring (dot);
        }
        for (int n = 1; n < 10000; n++) {
            dest = folder.get_child ("%s (%d)%s".printf (stem, n, ext));
            if (!dest.query_exists ())
                return dest;
        }
        return folder.get_child ("%s-%u%s".printf (stem, Random.next_int (), ext));
    }

    public static async void open_or_preview_file (File file, Gtk.Window? parent, bool force_open) throws Error {
        if (!force_open && yield preview_with_sushi (file))
            return;

        var launcher = new Gtk.FileLauncher (file);
        yield launcher.launch (parent, null);
    }

    public static async void open_or_preview_image_uri (string uri, Gtk.Window? parent) throws Error {
        var file = yield file_from_image_uri (uri);
        yield open_or_preview_file (file, parent, false);
    }

    public static async File file_from_image_uri (string uri) throws Error {
        if (uri.has_prefix ("data:"))
            return write_data_uri_image (uri);
        if (uri.has_prefix ("file:")) {
            var file = File.new_for_uri (uri);
            if (!file.query_exists ())
                throw new IOError.NOT_FOUND (_("The image could not be opened."));
            return file;
        }
        if (uri.has_prefix ("http://") || uri.has_prefix ("https://"))
            return yield download_image_uri (uri);
        throw new IOError.NOT_SUPPORTED (_("The image could not be opened."));
    }

    private static File write_data_uri_image (string uri) throws Error {
        var comma = uri.index_of_char (',');
        if (comma < 5)
            throw new IOError.INVALID_DATA (_("The image could not be opened."));

        var meta = uri.substring (5, comma - 5);
        var payload = uri.substring (comma + 1);
        var mime = "image/png";
        var is_base64 = false;
        foreach (var part in meta.split (";")) {
            if (part == "base64")
                is_base64 = true;
            else if (part.contains ("/"))
                mime = part;
        }

        uint8[] bytes;
        if (is_base64)
            bytes = Base64.decode (payload);
        else {
            var decoded = Uri.unescape_string (payload.replace ("+", "%20")) ?? payload;
            bytes = decoded.data;
        }
        if (bytes.length == 0)
            throw new IOError.INVALID_DATA (_("The image could not be opened."));
        return write_temp_image (bytes, mime);
    }

    private static async File download_image_uri (string uri) throws Error {
        var source = File.new_for_uri (uri);
        var name = image_name_from_uri (uri, "image/jpeg");
        var dir = File.new_for_path (Environment.get_tmp_dir ()).get_child (
            "mail-image-%u".printf (Random.next_int ())
        );
        dir.make_directory ();
        var dest = dir.get_child (name);
        yield source.copy_async (dest, FileCopyFlags.OVERWRITE, Priority.DEFAULT, null, null);
        return dest;
    }

    private static File write_temp_image (uint8[] bytes, string mime) throws Error {
        var dir = File.new_for_path (Environment.get_tmp_dir ()).get_child (
            "mail-image-%u".printf (Random.next_int ())
        );
        dir.make_directory ();
        var dest = dir.get_child ("image%s".printf (image_extension (mime)));
        string? etag;
        dest.replace_contents (bytes, null, false, FileCreateFlags.REPLACE_DESTINATION, out etag);
        return dest;
    }

    private static string image_extension (string mime) {
        var type = mime.strip ().down ();
        if (type.has_prefix ("image/jpeg") || type.has_prefix ("image/jpg"))
            return ".jpg";
        if (type.has_prefix ("image/png"))
            return ".png";
        if (type.has_prefix ("image/gif"))
            return ".gif";
        if (type.has_prefix ("image/webp"))
            return ".webp";
        if (type.has_prefix ("image/svg"))
            return ".svg";
        if (type.has_prefix ("image/bmp"))
            return ".bmp";
        return ".img";
    }

    private static string image_name_from_uri (string uri, string mime) {
        try {
            var parsed = Uri.parse (uri, UriFlags.ENCODED);
            var path = parsed.get_path ();
            if (path != null && path.length > 1) {
                var base_name = Path.get_basename (path);
                if (base_name.length > 0 && base_name.contains ("."))
                    return base_name;
            }
        } catch (Error e) {
        }
        return "image%s".printf (image_extension (mime));
    }

    private static async bool preview_with_sushi (File file) {
        try {
            var conn = yield Bus.get (BusType.SESSION, null);
            yield conn.call (
                "org.gnome.NautilusPreviewer",
                "/org/gnome/NautilusPreviewer",
                "org.gnome.NautilusPreviewer2",
                "ShowFile",
                new Variant ("(ssbs)", file.get_uri (), "", false, ""),
                null,
                DBusCallFlags.NONE,
                8000,
                null
            );
            return true;
        } catch (Error e) {
            debug ("Sushi preview is unavailable: %s", e.message);
            return false;
        }
    }

    public static void launch_desktop (string desktop_id) {
        var info = new DesktopAppInfo (desktop_id);
        if (info == null) {
            warning ("Desktop file %s is not installed", desktop_id);
            return;
        }

        try {
            info.launch (null, null);
        } catch (Error e) {
            warning ("Could not launch %s: %s", desktop_id, e.message);
        }
    }

    public const string NOTIFICATION_SOUND_DEFAULT = "message-new-instant";

    private static GSound.Context? sound_context;

    public static bool notification_sound_is_file (string choice) {
        return choice.has_prefix ("/") || choice.has_prefix ("file:");
    }

    public static string? notification_sound_filename (string choice) {
        if (choice.length == 0 || choice == "none")
            return null;
        if (choice.has_prefix ("/"))
            return FileUtils.test (choice, FileTest.IS_REGULAR) ? choice : null;
        if (choice.has_prefix ("file:")) {
            var file = File.new_for_uri (choice);
            var path = file.get_path ();
            if (path == null || !FileUtils.test (path, FileTest.IS_REGULAR))
                return null;
            return path;
        }
        return find_themed_sound (choice);
    }

    public static void play_notification_sound (string choice) {
        if (choice == "none")
            return;

        var ctx = ensure_sound_context ();
        if (ctx == null)
            return;

        var attrs = new HashTable<string, string> (str_hash, str_equal);
        attrs.set (GSound.Attribute.MEDIA_ROLE, "event");
        attrs.set (GSound.Attribute.EVENT_DESCRIPTION, "New mail");
        var path = notification_sound_filename (choice);
        if (path != null)
            attrs.set (GSound.Attribute.MEDIA_FILENAME, path);
        else
            attrs.set (
                GSound.Attribute.EVENT_ID,
                choice.length > 0 ? choice : NOTIFICATION_SOUND_DEFAULT
            );

        ctx.play_fullv.begin (attrs, null, (obj, res) => {
            try {
                ctx.play_fullv.end (res);
            } catch (Error e) {
                warning ("Could not play notification sound: %s", e.message);
            }
        });
    }

    private static GSound.Context? ensure_sound_context () {
        if (sound_context != null)
            return sound_context;

        try {
            var ctx = new GSound.Context ();
            ctx.open ();
            var attrs = new HashTable<string, string> (str_hash, str_equal);
            attrs.set (GSound.Attribute.APPLICATION_ID, Config.APP_ID);
            attrs.set (GSound.Attribute.APPLICATION_NAME, Utils.app_display_name ());
            ctx.set_attributesv (attrs);
            sound_context = ctx;
        } catch (Error e) {
            warning ("Could not init sound: %s", e.message);
            return null;
        }

        return sound_context;
    }

    private static string? find_themed_sound (string event_id) {
        var names = new GenericArray<string> ();
        names.add (event_id);
        var cursor = event_id;
        int dash;
        while ((dash = cursor.last_index_of_char ('-')) > 0) {
            cursor = cursor.substring (0, dash);
            names.add (cursor);
        }

        var themes = new GenericArray<string> ();
        var source = SettingsSchemaSource.get_default ();
        var schema = source != null ? source.lookup ("org.gnome.desktop.sound", true) : null;
        if (schema != null) {
            var desktop = new Settings ("org.gnome.desktop.sound");
            var theme = desktop.get_string ("theme-name");
            if (theme.length > 0 && theme != "freedesktop")
                themes.add (theme);
        }
        themes.add ("freedesktop");

        var roots = new GenericArray<string> ();
        roots.add (Path.build_filename (Environment.get_user_data_dir (), "sounds"));
        var system = Environment.get_system_data_dirs ();
        for (uint i = 0; i < system.length; i++)
            roots.add (Path.build_filename (system[i], "sounds"));

        string[] profiles = { "stereo", "posix", "" };
        string[] exts = { ".oga", ".ogg", ".wav" };
        for (uint n = 0; n < names.length; n++) {
            for (uint t = 0; t < themes.length; t++) {
                for (uint r = 0; r < roots.length; r++) {
                    for (uint p = 0; p < profiles.length; p++) {
                        for (uint e = 0; e < exts.length; e++) {
                            var path = profiles[p].length > 0
                                ? Path.build_filename (roots[r], themes[t], profiles[p], names[n] + exts[e])
                                : Path.build_filename (roots[r], themes[t], names[n] + exts[e]);
                            if (FileUtils.test (path, FileTest.IS_REGULAR))
                                return path;
                        }
                    }
                }
            }
        }

        return null;
    }

    public static bool has_microsoft365_calendar_backend () {
        return FileUtils.test (
            "/usr/lib/evolution-data-server/calendar-backends/libecalbackendmicrosoft365.so",
            FileTest.EXISTS
        );
    }

    public static bool has_microsoft365_mail_backend () {
        return FileUtils.test (
            "/usr/lib/evolution-data-server/camel-providers/libcamelmicrosoft365.so",
            FileTest.EXISTS
        );
    }

    public static GenericArray<string> spell_language_codes () {
        var languages = new GenericArray<string> ();
        var seen = new HashTable<string, uint8> (str_hash, str_equal);
        unowned string[] names = Intl.get_language_names ();
        foreach (unowned string name in names)
            add_spell_language (languages, seen, name);
        if (languages.length == 0)
            languages.add ("en_US");
        return languages;
    }

    private static void add_spell_language (
        GenericArray<string> languages,
        HashTable<string, uint8> seen,
        string locale
    ) {
        if (locale.length == 0 || locale == "C" || locale == "POSIX")
            return;

        var cleaned = locale;
        var dot = cleaned.index_of_char ('.');
        if (dot >= 0)
            cleaned = cleaned.substring (0, dot);
        var at = cleaned.index_of_char ('@');
        if (at >= 0)
            cleaned = cleaned.substring (0, at);
        if (cleaned.length == 0)
            return;

        if (!seen.contains (cleaned)) {
            seen.set (cleaned, 1);
            languages.add (cleaned);
        }

        var underscore = cleaned.index_of_char ('_');
        if (underscore <= 0)
            return;
        var lang = cleaned.substring (0, underscore);
        if (seen.contains (lang))
            return;
        seen.set (lang, 1);
        languages.add (lang);
    }

    public static bool hunspell_dictionaries_present () {
        return hunspell_dictionaries_present_for (spell_language_codes ());
    }

    public static bool hunspell_dictionaries_present_for (GenericArray<string> languages) {
        string[] roots = {
            "/usr/share/hunspell",
            "/usr/share/myspell",
            "/usr/share/myspell/dicts"
        };
        for (uint i = 0; i < languages.length; i++) {
            var code = languages[i].replace ("-", "_");
            foreach (unowned string root in roots) {
                if (FileUtils.test (Path.build_filename (root, code + ".dic"), FileTest.IS_REGULAR))
                    return true;
            }
        }
        return false;
    }

    public static void learn_enchant_word (string word, string[] languages) {
        var cleaned = word.strip ();
        if (cleaned.length == 0)
            return;

        var dir = Path.build_filename (Environment.get_user_config_dir (), "enchant");
        DirUtils.create_with_parents (dir, 0755);
        var written = new GenericSet<string> (str_hash, str_equal);
        foreach (var lang in languages) {
            var code = lang.replace ("-", "_");
            if (code.length == 0 || written.contains (code))
                continue;
            written.add (code);
            append_enchant_word (Path.build_filename (dir, code + ".dic"), cleaned);
        }
    }

    private static void append_enchant_word (string path, string word) {
        string existing = "";
        try {
            FileUtils.get_contents (path, out existing);
        } catch (Error e) {
            existing = "";
        }
        if (wordlist_contains (existing, word))
            return;

        try {
            var file = File.new_for_path (path);
            var stream = file.append_to (FileCreateFlags.NONE);
            if (existing.length > 0 && !existing.has_suffix ("\n"))
                stream.write ("\n".data);
            stream.write ((word + "\n").data);
            stream.close ();
        } catch (Error e) {
            warning ("Could not update spell dictionary: %s", e.message);
        }
    }

    private static bool wordlist_contains (string existing, string word) {
        if (existing.length == 0)
            return false;
        var padded = "\n" + existing.strip () + "\n";
        return padded.contains ("\n" + word + "\n");
    }

    public static bool program_installed (string name) {
        return Environment.find_program_in_path (name) != null;
    }

    public static bool shared_library_loadable (string name) {
        return Module.open (name, ModuleFlags.LAZY) != null;
    }

    public static bool has_gnome_online_accounts () {
        return shared_library_loadable ("libgoa-1.0.so.0")
            || shared_library_loadable ("libgoa-1.0.so")
            || FileUtils.test (
                "/usr/share/glib-2.0/schemas/org.gnome.online-accounts.gschema.xml",
                FileTest.EXISTS
            );
    }

    public static bool has_evolution_data_server () {
        return shared_library_loadable ("libedataserver-1.2.so.27")
            || shared_library_loadable ("libedataserver-1.2.so.26")
            || shared_library_loadable ("libedataserver-1.2.so")
            || FileUtils.test ("/usr/lib/evolution-data-server", FileTest.IS_DIR)
            || FileUtils.test ("/usr/lib64/evolution-data-server", FileTest.IS_DIR);
    }

    public static string display_address (string? from) {
        if (from == null || from.length == 0)
            return _("Unknown sender");

        var lt = from.index_of_char ('<');
        if (lt > 0) {
            var name = sanitize_recipient_text (from.substring (0, lt));
            if (name.length > 0)
                return name;
        }

        var cleaned = sanitize_recipient_text (from);
        return cleaned.length > 0 ? cleaned : from.strip ();
    }

    public static string display_address_list (string? raw) {
        if (raw == null || raw.strip ().length == 0)
            return "";

        var recipients = parse_recipient_list (raw);
        if (recipients.length == 0)
            return display_address (raw);

        var builder = new StringBuilder (recipients[0].chip_label);
        for (uint i = 1; i < recipients.length; i++) {
            builder.append (", ");
            builder.append (recipients[i].chip_label);
        }
        return builder.str;
    }

    public static string? email_from_header (string? value) {
        if (value == null || value.length == 0)
            return null;

        var text = value.strip ();
        var lt = text.index_of_char ('<');
        var gt = text.last_index_of_char ('>');
        if (lt >= 0 && gt > lt)
            text = text.substring (lt + 1, gt - lt - 1).strip ();

        if (!text.contains ("@"))
            return null;

        return text.down ();
    }

    public static string format_message_datetime (int64 unix_time) {
        if (unix_time <= 0)
            return "";

        return new DateTime.from_unix_local (unix_time).format ("%d %b %Y · %H:%M");
    }

    public static GenericArray<Recipient> recipients_from_address (Camel.InternetAddress? address) {
        var result = new GenericArray<Recipient> ();
        if (address == null)
            return result;

        for (int i = 0; i < address.length (); i++) {
            string? name;
            string? email;
            if (!address.get (i, out name, out email))
                continue;

            var addr = sanitize_recipient_text (email);
            var display = sanitize_recipient_text (name);
            if (addr.length == 0)
                addr = display;
            if (addr.length == 0 && display.length == 0)
                continue;

            if (addr.has_prefix ("mailto:"))
                addr = addr.substring (7).strip ();
            if (addr.has_prefix ("<") && addr.has_suffix (">") && addr.length > 2)
                addr = addr.substring (1, addr.length - 2).strip ();

            result.add (new Recipient () {
                name = display,
                email = addr,
            });
        }

        return result;
    }

    public static string sanitize_recipient_text (string? raw) {
        if (raw == null || raw.length == 0)
            return "";

        var text = raw.replace ("\\\"", "\"").replace ("\\'", "'");
        text = text.replace ("&quot;", "\"").replace ("&#39;", "'").replace ("&apos;", "'");
        text = text.replace ("\u200b", "").replace ("\u00a0", " ");
        text = text.strip ();

        while (text.length > 0) {
            var next = unwrap_matching_quotes (text);
            if (next == text)
                break;
            text = next.strip ();
        }

        while (text.length > 0 && is_wrapping_quote (text.get_char (0))) {
            int next = text.index_of_nth_char (1);
            text = (next < 0 || next >= text.length) ? "" : text.substring (next).strip ();
        }

        while (text.length > 0) {
            int last = text.index_of_nth_char (text.char_count () - 1);
            unichar c = text.get_char (last);
            if (c == '"' || c == '`' || c == 0x201C || c == 0x201D || c == 0x00AB || c == 0x00BB) {
                text = text.substring (0, last).strip ();
                continue;
            }
            break;
        }

        while (text.has_suffix (",") || text.has_suffix (";"))
            text = text.substring (0, text.length - 1).strip ();

        return collapse_spaces (text);
    }

    private static string unwrap_matching_quotes (string text) {
        if (text.char_count () < 2)
            return text;

        unichar first = text.get_char (0);
        int last = text.index_of_nth_char (text.char_count () - 1);
        unichar end = text.get_char (last);
        if (!is_wrapping_quote (first) || !is_wrapping_quote (end))
            return text;

        int inner = text.index_of_nth_char (1);
        return text.substring (inner, last - inner);
    }

    private static bool is_wrapping_quote (unichar c) {
        return c == '"'
            || c == '\''
            || c == '`'
            || c == 0x2018
            || c == 0x2019
            || c == 0x201C
            || c == 0x201D
            || c == 0x00AB
            || c == 0x00BB;
    }

    private static string collapse_spaces (string text) {
        var builder = new StringBuilder ();
        bool space = false;
        int index = 0;
        unichar c;
        while (text.get_next_char (ref index, out c)) {
            if (c.isspace ()) {
                space = builder.len > 0;
                continue;
            }
            if (space)
                builder.append_c (' ');
            space = false;
            builder.append_unichar (c);
        }

        return builder.str;
    }

    public static string format_internet_address (Camel.InternetAddress? address) {
        if (address == null || address.length () == 0)
            return "";

        return address.format () ?? "";
    }

    public static string? address_email (Camel.InternetAddress? address) {
        if (address == null || address.length () == 0)
            return null;

        string? name;
        string? email;
        if (!address.get (0, out name, out email))
            return null;

        if (email == null || email.strip ().length == 0)
            return null;

        return email.strip ().down ();
    }

    public static void append_search_part (StringBuilder haystack, string? value) {
        if (value == null || value.length == 0)
            return;
        if (haystack.len > 0)
            haystack.append_c (' ');
        haystack.append (value.casefold ());
    }

    public static GenericArray<string> search_tokens (string query) {
        var tokens = new GenericArray<string> ();
        int i = 0;
        unichar c;
        while (i < query.length) {
            var next = i;
            query.get_next_char (ref next, out c);
            if (c.isspace ()) {
                i = next;
                continue;
            }
            if (c == '"') {
                i = next;
                var inner = new StringBuilder ();
                while (i < query.length) {
                    next = i;
                    query.get_next_char (ref next, out c);
                    if (c == '"') {
                        i = next;
                        break;
                    }
                    inner.append_unichar (c);
                    i = next;
                }
                var token = inner.str.strip ();
                if (token.length > 0)
                    tokens.add (token);
                continue;
            }

            var word = new StringBuilder ();
            while (i < query.length) {
                next = i;
                query.get_next_char (ref next, out c);
                if (c.isspace ())
                    break;
                word.append_unichar (c);
                i = next;
            }
            if (word.len > 0)
                tokens.add (word.str);
        }
        return tokens;
    }

    public static bool haystack_matches_tokens (string haystack, GenericArray<string> tokens) {
        if (tokens.length == 0)
            return haystack.length > 0;
        for (uint i = 0; i < tokens.length; i++) {
            if (!haystack.contains (tokens[i]))
                return false;
        }
        return true;
    }

    public static Pango.AttrList? search_highlight_attrs (string text, GenericArray<string>? tokens) {
        if (tokens == null || tokens.length == 0 || text.length == 0)
            return null;

        var order = new uint[tokens.length];
        for (uint i = 0; i < tokens.length; i++)
            order[i] = i;
        for (uint i = 1; i < order.length; i++) {
            var item = order[i];
            uint j = i;
            while (j > 0 && tokens[order[j - 1]].length < tokens[item].length) {
                order[j] = order[j - 1];
                j--;
            }
            order[j] = item;
        }

        var occupied = new bool[text.length];
        var attrs = new Pango.AttrList ();
        bool any = false;
        for (uint t = 0; t < order.length; t++) {
            var token = tokens[order[t]];
            if (token.length == 0)
                continue;
            int i = 0;
            while (i < text.length) {
                int end;
                if (!search_token_at (text, i, token, out end)) {
                    unichar c;
                    text.get_next_char (ref i, out c);
                    continue;
                }

                bool overlap = false;
                for (int b = i; b < end; b++) {
                    if (occupied[b]) {
                        overlap = true;
                        break;
                    }
                }
                if (!overlap) {
                    for (int b = i; b < end; b++)
                        occupied[b] = true;
                    var bg = Pango.attr_background_new (0xf5 * 257, 0xc2 * 257, 0x11 * 257);
                    bg.start_index = i;
                    bg.end_index = end;
                    attrs.insert ((owned) bg);
                    var fg = Pango.attr_foreground_new (0x1c * 257, 0x1c * 257, 0x1c * 257);
                    fg.start_index = i;
                    fg.end_index = end;
                    attrs.insert ((owned) fg);
                    any = true;
                }
                i = end;
            }
        }

        return any ? attrs : null;
    }

    private static bool search_token_at (string text, int start, string folded_token, out int end) {
        end = start;
        int ti = 0;
        int i = start;
        unichar c;
        unichar tc;
        if (folded_token.length == 0)
            return false;
        while (ti < folded_token.length) {
            if (i >= text.length)
                return false;
            int next = i;
            int tnext = ti;
            text.get_next_char (ref next, out c);
            folded_token.get_next_char (ref tnext, out tc);
            if (c.tolower () != tc)
                return false;
            i = next;
            ti = tnext;
        }
        end = i;
        return true;
    }

    public static string? normalize_email (string? email) {
        if (email == null)
            return null;

        var needle = email.strip ().down ();
        if (needle.length == 0 || !needle.contains ("@"))
            return null;
        return needle;
    }

    public static bool emails_equal (string? a, string? b) {
        var left = normalize_email (a);
        var right = normalize_email (b);
        return left != null && left == right;
    }

    public static string? email_domain (string? email) {
        var needle = normalize_email (email);
        if (needle == null)
            return null;

        var at = needle.last_index_of_char ('@');
        if (at < 0 || at + 1 >= needle.length)
            return null;
        return needle.substring (at + 1);
    }

    public static bool same_mail_domain (string? a, string? b) {
        var left = email_domain (a);
        var right = email_domain (b);
        return left != null && left == right;
    }

    public static bool mailbox_uses_org_trust (Account? account) {
        return account != null
            && (account.kind == AccountKind.MICROSOFT || account.kind == AccountKind.EXCHANGE);
    }

    public static bool is_mailbox_sender (string? email, Account? account, Identity? identity) {
        if (emails_equal (email, account != null ? account.email : null))
            return true;
        if (identity == null)
            return false;
        if (emails_equal (email, identity.address))
            return true;
        if (identity.aliases == null)
            return false;
        foreach (var alias in identity.aliases) {
            if (emails_equal (email, alias))
                return true;
        }
        return false;
    }

    public static bool is_organization_sender (string? email, Account? account, Identity? identity) {
        if (!mailbox_uses_org_trust (account))
            return false;

        var domain = email_domain (email);
        if (domain == null || is_consumer_mail_domain (domain))
            return false;

        if (matches_org_domain (domain, account != null ? account.email : null))
            return true;
        if (identity == null)
            return false;
        if (matches_org_domain (domain, identity.address))
            return true;
        if (identity.aliases == null)
            return false;
        foreach (var alias in identity.aliases) {
            if (matches_org_domain (domain, alias))
                return true;
        }
        return false;
    }

    public static bool remote_content_allowed (
        Settings settings,
        string? email,
        Account? account,
        Identity? identity,
        bool outgoing
    ) {
        if (outgoing || is_mailbox_sender (email, account, identity))
            return true;
        if (is_trusted_sender (settings, email))
            return true;
        return is_organization_sender (email, account, identity);
    }

    private static bool matches_org_domain (string domain, string? mailbox_email) {
        var mine = email_domain (mailbox_email);
        return mine != null && mine == domain && !is_consumer_mail_domain (mine);
    }

    private static bool is_consumer_mail_domain (string domain) {
        switch (domain) {
            case "outlook.com":
            case "hotmail.com":
            case "live.com":
            case "msn.com":
            case "outlook.it":
            case "hotmail.it":
            case "live.it":
                return true;
            default:
                return false;
        }
    }

    public static bool html_has_remote_images (string html) {
        var down = html.down ();
        return down.contains ("src=\"http://")
            || down.contains ("src=\"https://")
            || down.contains ("src='http://")
            || down.contains ("src='https://")
            || down.contains ("src=http://")
            || down.contains ("src=https://")
            || down.contains ("url(http://")
            || down.contains ("url(https://")
            || down.contains ("url(\"http")
            || down.contains ("url('http");
    }

    public static bool is_trusted_sender (Settings settings, string? email) {
        var needle = normalize_email (email);
        if (needle == null)
            return false;

        var trusted = settings.get_strv ("trusted-senders");
        foreach (var item in trusted) {
            if (normalize_email (item) == needle)
                return true;
        }

        return false;
    }

    public static void trust_sender (Settings settings, string email) {
        var needle = normalize_email (email);
        if (needle == null || is_trusted_sender (settings, needle))
            return;

        string[] next = {};
        foreach (var item in settings.get_strv ("trusted-senders"))
            next += item;
        next += needle;
        settings.set_strv ("trusted-senders", next);
    }

    public static string format_recipient (Recipient recipient) {
        var listed = new GenericArray<Recipient> ();
        listed.add (recipient);
        return format_recipient_list (listed);
    }

    public static string format_mailbox (string? name, string? email) {
        return format_recipient (new Recipient () {
            name = name ?? "",
            email = email ?? "",
        });
    }

    public static void reply_all_addresses (
        MessageContent content,
        string? self_email,
        out string to,
        out string? cc
    ) {
        var skip = new GenericSet<string> (str_hash, str_equal);
        if (self_email != null && self_email.strip ().length > 0)
            skip.add (self_email.strip ().down ());

        var seen = new GenericSet<string> (str_hash, str_equal);
        var to_parts = new GenericArray<string> ();
        add_address_part (to_parts, seen, skip, content.from_email, content.from);
        append_recipient_parts (to_parts, seen, skip, content.to_recipients);

        var cc_parts = new GenericArray<string> ();
        append_recipient_parts (cc_parts, seen, skip, content.cc_recipients);

        to = join_address_parts (to_parts);
        cc = cc_parts.length > 0 ? join_address_parts (cc_parts) : null;
    }

    public static void resend_addresses (
        MessageContent content,
        out string to,
        out string? cc,
        out string? bcc
    ) {
        to = nonempty_recipient_text (content.to_recipients, content.to) ?? "";
        cc = nonempty_recipient_text (content.cc_recipients, content.cc);
        bcc = nonempty_recipient_text (content.bcc_recipients, content.bcc);
    }

    private static string? nonempty_recipient_text (GenericArray<Recipient>? recipients, string? fallback) {
        if (recipients != null && recipients.length > 0) {
            var listed = format_recipient_list (recipients);
            if (listed.strip ().length > 0)
                return listed;
        }
        if (fallback == null)
            return null;
        var stripped = fallback.strip ();
        return stripped.length > 0 ? stripped : null;
    }

    private static void add_address_part (
        GenericArray<string> parts,
        GenericSet<string> seen,
        GenericSet<string> skip,
        string? email_raw,
        string? display
    ) {
        var email = sanitize_recipient_text (email_raw);
        if (email.length == 0)
            email = email_from_header (display) ?? "";
        email = email.strip ().down ();
        if (email.length == 0 || skip.contains (email) || seen.contains (email))
            return;

        seen.add (email);
        var name = display_address (display);
        if (name.length == 0 || name == _("Unknown sender") || name.down () == email)
            parts.add (email);
        else
            parts.add (format_mailbox (name, email));
    }

    private static void append_recipient_parts (
        GenericArray<string> parts,
        GenericSet<string> seen,
        GenericSet<string> skip,
        GenericArray<Recipient>? recipients
    ) {
        if (recipients == null)
            return;

        for (uint i = 0; i < recipients.length; i++) {
            var recipient = recipients[i];
            var email = sanitize_recipient_text (recipient.email).down ();
            if (email.length == 0 || skip.contains (email) || seen.contains (email))
                continue;

            seen.add (email);
            parts.add (format_recipient (recipient));
        }
    }

    private static string join_address_parts (GenericArray<string> parts) {
        if (parts.length == 0)
            return "";

        var builder = new StringBuilder (parts[0]);
        for (uint i = 1; i < parts.length; i++) {
            builder.append (", ");
            builder.append (parts[i]);
        }
        return builder.str;
    }

    public static string quote_attribution (MessageContent content) {
        var header = new StringBuilder ();
        header.append (_("On %s, %s wrote").printf (format_message_datetime (content.date), content.from));
        var to = format_quote_recipients (content.to_recipients, content.to);
        if (to.length > 0) {
            header.append ("\n");
            header.append (_("To:"));
            header.append (" ");
            header.append (to);
        }

        var cc = format_quote_recipients (content.cc_recipients, content.cc);
        if (cc.length > 0) {
            header.append ("\n");
            header.append (_("Cc:"));
            header.append (" ");
            header.append (cc);
        }

        return header.str;
    }

    public static string compose_edit_fragment (MessageContent content) {
        return unwrap_mail_compose (quote_html_fragment (content)).strip ();
    }

    private static string unwrap_mail_compose (string html) {
        try {
            var re = new Regex (
                "^\\s*<div\\b[^>]*\\bclass=\"[^\"]*\\bmail-compose\\b[^\"]*\"[^>]*>([\\s\\S]*)</div>\\s*$",
                RegexCompileFlags.CASELESS
            );
            MatchInfo info;
            if (re.match (html, 0, out info)) {
                var inner = info.fetch (1);
                if (inner != null)
                    return inner;
            }
        } catch (Error e) {
        }

        return html;
    }

    public static string quote_html_fragment (MessageContent content) {
        var html = content.html;
        if (html == null || html.strip ().length == 0) {
            var text = quote_message_body (content);
            return text.length == 0 ? "" : Markup.escape_text (text).replace ("\n", "<br>\n");
        }

        html = extract_html_body (html);
        html = replace_html_regex (html, "<!--\\[if[\\s\\S]*?<!\\[endif\\]-->", "");
        html = replace_html_regex (html, "<!--[\\s\\S]*?-->", "");
        html = replace_html_regex (html, "<(script|style|head|title|meta|link)[\\s\\S]*?</\\1>", "");
        html = replace_html_regex (html, "<(script|style|meta|link)\\b[^>]*/?>", "");
        html = replace_html_regex (html, "<xml[\\s\\S]*?</xml>", "");
        html = replace_html_regex (html, "</?[ovw]:[^>]*>", "");
        html = replace_html_regex (html, "\\[signature_\\d+\\]", "");
        html = strip_auto_image_alts (html);
        return html.strip ();
    }

    public static string quote_attribution_html (MessageContent content) {
        return Markup.escape_text (quote_attribution (content)).replace ("\n", "<br>\n");
    }

    public static string quote_message_body (MessageContent content) {
        string raw = "";
        if (content.html != null && content.html.length > 0)
            raw = html_to_quote_text (content.html);
        if (raw.strip ().length < 8 && content.plain_text != null && content.plain_text.length > 0)
            raw = content.plain_text;
        return clean_quote_text (raw);
    }

    public static string quote_body_text (string? text) {
        return clean_quote_text (text);
    }

    private static string format_quote_recipients (GenericArray<Recipient>? recipients, string? fallback) {
        if (recipients != null && recipients.length > 0) {
            var builder = new StringBuilder (format_recipient (recipients[0]));
            for (uint i = 1; i < recipients.length; i++) {
                builder.append ("; ");
                builder.append (format_recipient (recipients[i]));
            }
            return builder.str;
        }

        return fallback != null ? fallback.strip () : "";
    }

    private static string html_to_quote_text (string html) {
        var text = collapse_data_uris (html);
        text = replace_html_regex (text, "<!--\\[if[\\s\\S]*?<!\\[endif\\]-->", "");
        text = replace_html_regex (text, "<!--[\\s\\S]*?-->", "");
        text = replace_html_regex (text, "<(script|style|head|title)[\\s\\S]*?</\\1>", "");
        text = replace_html_links (text);
        text = replace_html_images (text);
        text = replace_html_regex (text, "<br\\s*/?>", "\n");
        text = replace_html_regex (text, "</(p|div|tr|h[1-6]|li|table|blockquote)>", "\n");
        text = replace_html_regex (text, "<hr\\s*/?>", "\n");
        text = replace_html_regex (text, "<li\\b[^>]*>", "• ");
        text = replace_html_regex (text, "<[^>]+>", "");
        text = decode_html_entities (text);
        return text;
    }

    private static string collapse_data_uris (string html) {
        var builder = new StringBuilder ();
        uint8[] data = html.data;
        int i = 0;
        while (i < data.length) {
            int start = index_of_ascii (data, i, "data:");
            if (start < 0) {
                builder.append (html.substring (i));
                break;
            }

            builder.append (html.substring (i, start - i));
            builder.append ("image.png");
            i = start + 5;
            while (i < data.length) {
                var b = data[i];
                if (b == '"' || b == '\'' || b == '>' || b == ' ' || b == '\t' || b == '\n' || b == '\r')
                    break;
                i++;
            }
        }

        return builder.str;
    }

    private static int index_of_ascii (uint8[] data, int from, string needle) {
        uint8[] find = needle.data;
        if (find.length == 0 || from >= data.length)
            return -1;

        int last = data.length - find.length;
        for (int i = from; i <= last; i++) {
            bool match = true;
            for (int j = 0; j < find.length; j++) {
                if (data[i + j] != find[j]) {
                    match = false;
                    break;
                }
            }
            if (match)
                return i;
        }

        return -1;
    }

    private static string replace_html_links (string html) {
        try {
            var re = new Regex (
                "<a\\b[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>",
                RegexCompileFlags.CASELESS
            );
            return re.replace_eval (html, html.length, 0, 0, (match, builder) => {
                var href = decode_href (match.fetch (1) ?? "");
                var inner = strip_tags (match.fetch (2) ?? "").strip ();
                if (inner.length > 0)
                    builder.append (inner);
                else if (href.length > 0)
                    builder.append (href);
                return false;
            });
        } catch (Error e) {
            return html;
        }
    }

    private static string replace_html_images (string html) {
        try {
            var re = new Regex ("<img\\b[^>]*>", RegexCompileFlags.CASELESS);
            return re.replace_eval (html, html.length, 0, 0, (match, builder) => {
                builder.append (" <");
                builder.append (image_placeholder (match.fetch (0) ?? ""));
                builder.append ("> ");
                return false;
            });
        } catch (Error e) {
            return html;
        }
    }

    private static string image_placeholder (string tag) {
        var src = html_attr (tag, "src");
        var name = filename_from_src (src);
        if (name.length > 0)
            return name;
        return "image.png";
    }

    private static string extract_html_body (string html) {
        try {
            var re = new Regex ("<body[^>]*>([\\s\\S]*)</body>", RegexCompileFlags.CASELESS);
            MatchInfo info;
            if (re.match (html, 0, out info)) {
                var body = info.fetch (1);
                if (body != null && body.strip ().length > 0)
                    return body;
            }
        } catch (Error e) {
        }

        return html;
    }

    private static string strip_auto_image_alts (string html) {
        try {
            var re = new Regex ("<img\\b[^>]*>", RegexCompileFlags.CASELESS);
            return re.replace_eval (html, html.length, 0, 0, (match, builder) => {
                var tag = match.fetch (0) ?? "";
                var alt = html_attr (tag, "alt");
                if (is_auto_image_alt (alt)) {
                    try {
                        var alt_re = new Regex ("\\s+alt\\s*=\\s*(\"[^\"]*\"|'[^']*')", RegexCompileFlags.CASELESS);
                        tag = alt_re.replace (tag, tag.length, 0, "");
                    } catch (Error e) {
                    }
                }
                builder.append (tag);
                return false;
            });
        } catch (Error e) {
            return html;
        }
    }

    private static bool is_auto_image_alt (string alt) {
        if (alt.length == 0)
            return false;
        var down = alt.down ();
        return down.contains ("descrizione generata automaticamente")
            || down.contains ("automatically generated description")
            || down.contains ("immagine che contiene")
            || down.contains ("image contains");
    }

    private static string html_attr (string tag, string name) {
        try {
            var re = new Regex (
                "%s\\s*=\\s*[\"']([^\"']*)[\"']".printf (Regex.escape_string (name)),
                RegexCompileFlags.CASELESS
            );
            MatchInfo info;
            if (re.match (tag, 0, out info))
                return info.fetch (1) ?? "";
        } catch (Error e) {
        }

        return "";
    }

    private static string filename_from_src (string? src) {
        if (src == null || src.length == 0)
            return "";

        var value = src.strip ();
        if (value.has_prefix ("cid:")) {
            value = value.substring (4);
            var at = value.index_of_char ('@');
            if (at > 0)
                value = value.substring (0, at);
        }

        var slash = value.last_index_of_char ('/');
        if (slash >= 0 && slash + 1 < value.length)
            value = value.substring (slash + 1);
        var query = value.index_of_char ('?');
        if (query > 0)
            value = value.substring (0, query);

        value = Uri.unescape_string (value) ?? value;
        if (value == "image.png" || value.length == 0)
            return "image.png";
        if (looks_like_filename (value))
            return value;
        return "image.png";
    }

    private static bool looks_like_filename (string value) {
        if (value.contains (" ") || value.length > 80)
            return false;
        var dot = value.last_index_of_char ('.');
        return dot > 0 && dot < value.length - 1;
    }

    private static string decode_href (string href) {
        var value = href.strip ();
        if (value.has_prefix ("mailto:"))
            return Uri.unescape_string (value.substring (7)) ?? value.substring (7);
        if (value.has_prefix ("tel:"))
            return Uri.unescape_string (value.substring (4)) ?? value.substring (4);
        return value;
    }

    private static string replace_html_regex (string text, string pattern, string replacement) {
        try {
            var re = new Regex (pattern, RegexCompileFlags.CASELESS);
            return re.replace (text, text.length, 0, replacement);
        } catch (Error e) {
            return text;
        }
    }

    private static string strip_tags (string text) {
        return replace_html_regex (text, "<[^>]+>", "");
    }

    private static string decode_html_entities (string text) {
        var result = text
            .replace ("&nbsp;", " ")
            .replace ("&amp;", "&")
            .replace ("&lt;", "<")
            .replace ("&gt;", ">")
            .replace ("&quot;", "\"")
            .replace ("&#39;", "'")
            .replace ("&apos;", "'");
        try {
            var re = new Regex ("&#(x?[0-9a-fA-F]+);");
            result = re.replace_eval (result, result.length, 0, 0, (match, builder) => {
                var token = match.fetch (1) ?? "";
                unichar code = 0;
                if (token.has_prefix ("x") || token.has_prefix ("X"))
                    code = (unichar) uint64.parse (token.substring (1), 16);
                else
                    code = (unichar) uint64.parse (token);
                if (code != 0)
                    builder.append_unichar (code);
                return false;
            });
        } catch (Error e) {
        }

        return result;
    }

    private static string clean_quote_text (string? text) {
        if (text == null || text.length == 0)
            return "";

        var normalized = text.replace ("\r\n", "\n").replace ("\r", "\n");
        normalized = replace_html_regex (normalized, "\\[signature_\\d+\\]", "");
        normalized = replace_html_regex (
            normalized,
            "\\[(?:cid:[^\\]]+|Immagine che contiene[^\\]]*|Image contains[^\\]]*|[^\\]]*(?:Descrizione generata automaticamente|Automatically generated description)[^\\]]*)\\]",
            ""
        );
        normalized = replace_angle_hrefs (normalized);

        var builder = new StringBuilder ();
        foreach (var line in normalized.split ("\n")) {
            var stripped = line;
            while (stripped.has_prefix (">")) {
                stripped = stripped.substring (1);
                if (stripped.has_prefix (" "))
                    stripped = stripped.substring (1);
            }
            stripped = stripped.chomp ();
            builder.append (stripped);
            builder.append ("\n");
        }

        return collapse_blank_lines (builder.str).chomp ();
    }

    private static string replace_angle_hrefs (string text) {
        try {
            var re = new Regex ("<(mailto:|tel:|https?:)([^>]+)>", RegexCompileFlags.CASELESS);
            return re.replace_eval (text, text.length, 0, 0, (match, builder) => {
                var scheme = match.fetch (1) ?? "";
                var rest = match.fetch (2) ?? "";
                builder.append (decode_href (scheme + rest));
                return false;
            });
        } catch (Error e) {
            return text;
        }
    }

    private static string collapse_blank_lines (string text) {
        var builder = new StringBuilder ();
        int empty = 0;
        foreach (var line in text.split ("\n")) {
            if (line.strip ().length == 0) {
                empty++;
                if (empty <= 1)
                    builder.append ("\n");
                continue;
            }

            empty = 0;
            builder.append (line);
            builder.append ("\n");
        }

        return builder.str;
    }

    public static GenericArray<Recipient> parse_recipient_list (string? raw) {
        return recipients_from_address (internet_address_from_header (raw));
    }

    public static Camel.InternetAddress internet_address_from_header (string? raw) {
        var address = new Camel.InternetAddress ();
        if (raw != null && raw.strip ().length > 0)
            address.decode (quote_unquoted_angle_names (raw.strip ()));
        return address;
    }

    public static string format_recipient_list (GenericArray<Recipient> recipients) {
        var address = new Camel.InternetAddress ();
        for (uint i = 0; i < recipients.length; i++)
            add_recipient_to_address (address, recipients[i]);
        if (address.length () == 0)
            return "";
        return address.encode () ?? "";
    }

    private static void add_recipient_to_address (Camel.InternetAddress address, Recipient recipient) {
        var email = sanitize_recipient_text (recipient.email);
        var name = sanitize_recipient_text (recipient.name);
        if (email.length == 0 && name.contains ("@")) {
            email = name;
            name = "";
        }
        if (email.length == 0 && name.length == 0)
            return;
        if (email.length == 0)
            address.add ("", name);
        else if (name.length == 0 || name.down () == email.down () || name.contains ("@"))
            address.add ("", email);
        else
            address.add (name, email);
    }

    private static string quote_unquoted_angle_names (string raw) {
        if (raw.index_of_char ('<') < 0)
            return raw;

        var result = new StringBuilder ();
        int cursor = 0;
        var first = true;
        while (cursor < raw.length) {
            while (cursor < raw.length) {
                var c = raw[cursor];
                if (c != ' ' && c != '\t' && c != ',' && c != ';')
                    break;
                cursor++;
            }
            if (cursor >= raw.length)
                break;

            var lt = raw.index_of_char ('<', cursor);
            if (lt < 0) {
                var rest = raw.substring (cursor).strip ();
                if (rest.length > 0) {
                    if (!first)
                        result.append (", ");
                    result.append (rest);
                }
                break;
            }

            var gt = raw.index_of_char ('>', lt);
            if (gt < 0) {
                var rest = raw.substring (cursor).strip ();
                if (rest.length > 0) {
                    if (!first)
                        result.append (", ");
                    result.append (rest);
                }
                break;
            }

            var name = raw.substring (cursor, lt - cursor).strip ();
            var angle = raw.substring (lt, gt - lt + 1);
            if (!first)
                result.append (", ");
            first = false;

            if (name.length > 0
                && !name.has_prefix ("\"")
                && (name.contains (",") || name.contains (";"))) {
                result.append ("\"");
                result.append (name.replace ("\"", "\\\""));
                result.append ("\" ");
            } else if (name.length > 0) {
                result.append (name);
                result.append (" ");
            }
            result.append (angle);
            cursor = gt + 1;
        }
        return result.str;
    }

    public static string reply_subject (string subject) {
        var core = Conversation.display_subject (subject);
        if (core == _("(No subject)"))
            return "Re:";
        return "Re: %s".printf (core);
    }

    public static string forward_subject (string subject) {
        var core = Conversation.display_subject (subject);
        if (core == _("(No subject)"))
            return "Fwd:";
        return "Fwd: %s".printf (core);
    }

    public static uint sendable_account_count (AccountStore store) {
        uint count = 0;
        for (uint i = 0; i < store.items.get_n_items (); i++) {
            var account = (Account) store.items.get_item (i);
            if (is_sendable (account))
                count++;
        }
        return count;
    }

    public static Gtk.Image account_brand_image (Account account, int pixel_size = 32) {
        Gtk.Image image;
        if (account.provider_icon != null && account.provider_icon.length > 0) {
            try {
                image = new Gtk.Image.from_gicon (Icon.new_for_string (account.provider_icon));
            } catch (Error e) {
                image = new Gtk.Image.from_icon_name (account.kind.icon_name ());
            }
        } else {
            image = new Gtk.Image.from_icon_name (account.kind.icon_name ());
        }
        image.pixel_size = pixel_size;
        return image;
    }

    public static bool is_sendable (Account account) {
        return account.kind != AccountKind.LOCAL && account.source_uid != null && account.has_mail;
    }

    public static string friendly_send_error (Error error) {
        if (error is IOError)
            return error.message;

        var raw = error.message ?? "";
        var down = raw.down ();
        var recipient = extract_quoted_recipient (raw);

        if (down.contains ("errorinvalidrecipients")
            || down.contains ("not resolved")
            || (down.contains ("recipient") && (down.contains ("not valid") || down.contains ("invalid")))) {
            if (recipient != null)
                return _("“%s” is not a valid email address.").printf (recipient);
            return _("Check the recipients. At least one address is not valid.");
        }

        if (down.contains ("erroraccessdenied") || down.contains ("access denied") || down.contains ("forbidden"))
            return _("You do not have permission to send this message.");

        if (down.contains ("quota") || down.contains ("mailboxfull") || down.contains ("mailbox full"))
            return _("The mailbox is full. The message could not be sent.");

        if (down.contains ("timeout") || down.contains ("timed out"))
            return _("The server took too long to respond. Try again.");

        if (down.contains ("not connected") || down.contains ("offline") || down.contains ("network unreachable"))
            return _("Could not reach the mail server. Check your connection.");

        if (down.contains ("cancelled") || down.contains ("canceled"))
            return _("The message was not sent.");

        return _("The message could not be sent.");
    }

    private static string? extract_quoted_recipient (string raw) {
        var start = raw.index_of ("Recipient '");
        if (start < 0)
            start = raw.index_of ("recipient '");
        if (start < 0)
            return null;

        start = raw.index_of_char ('\'', start);
        if (start < 0)
            return null;

        var end = raw.index_of_char ('\'', start + 1);
        if (end <= start + 1)
            return null;

        return raw.substring (start + 1, end - start - 1);
    }

    public static string format_message_date (int64 unix_time) {
        if (unix_time <= 0)
            return "";

        var dt = new DateTime.from_unix_local (unix_time);
        var now = new DateTime.now_local ();
        if (dt.get_year () == now.get_year () && dt.get_day_of_year () == now.get_day_of_year ())
            return dt.format ("%H:%M");
        if (dt.get_year () == now.get_year ())
            return dt.format ("%d %b");
        return dt.format ("%d %b %Y");
    }
}
