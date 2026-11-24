/**
 * On-disk Letter Identity account catalog (Phase 1).
 * Passwords live in libsecret — never in this JSON.
 *
 * Path: $XDG_DATA_HOME/letter/identity/accounts.json
 */
public class Mail.IdentityAccount : Object {
    public string id { get; set; }
    public string kind { get; set; default = "imap"; }
    /** "password" (IMAP LOGIN) or "oauth2" (XOAUTH2). */
    public string auth_method { get; set; default = "password"; }
    /**
     * Local label in the account rail / Preferences — not the From: header.
     * e.g. “Gmail personale”.
     */
    public string display_name { get; set; }
    /**
     * Name recipients see on sent mail (From). Null/empty → use display_name
     * for older catalogs that only stored one field.
     */
    public string? sender_name { get; set; }
    public string email { get; set; }
    public string username { get; set; }
    public string imap_host { get; set; }
    public uint imap_port { get; set; default = 993; }
    public bool imap_tls { get; set; default = true; }
    public string? smtp_host { get; set; }
    public uint smtp_port { get; set; default = 465; }
    public bool smtp_tls { get; set; default = true; }
    public bool enabled { get; set; default = true; }

    public bool uses_oauth2 () {
        return (this.auth_method ?? "password").down () == "oauth2";
    }

    /** From: display name for outgoing mail. */
    public string effective_sender_name () {
        var s = this.sender_name != null ? this.sender_name.strip () : "";
        if (s.length > 0)
            return s;
        return this.display_name ?? this.email ?? "";
    }

    public Account to_account () {
        AccountKind ak = AccountKind.IMAP;
        var k = (this.kind ?? "imap").down ();
        var host = (this.imap_host ?? "").down ();
        /* Gmail IMAP must be GOOGLE so UI hides virtual Bookmarks and uses
         * Starred (Speciali) — same as GOA Gmail accounts. */
        if (k == "google"
            || host.contains ("gmail.com")
            || host.contains ("googlemail.com"))
            ak = AccountKind.GOOGLE;
        else if (k == "microsoft" || k == "ms365"
            || host.contains ("outlook.")
            || host.contains ("office365.")
            || host.contains ("hotmail."))
            ak = AccountKind.MICROSOFT;

        /* Omit nullables set to null (Vala `_g_free0 (NULL)`). source_uid must
         * be the Identity id — Utils.is_sendable / outbox keys require it. */
        return new Account () {
            uid = this.id,
            source_uid = this.id,
            display_name = this.display_name,
            email = this.email,
            kind = ak,
            has_mail = this.enabled,
            has_calendar = false,
            has_contacts = false,
            backend_name = "letter-imap",
            enabled = this.enabled,
        };
    }
}

public class Mail.IdentityCatalog : Object {
    public const uint FORMAT_VERSION = 1;

    private GenericArray<IdentityAccount> _accounts;

    public GenericArray<IdentityAccount> accounts {
        get { return this._accounts; }
    }

    public IdentityCatalog () {
        this._accounts = new GenericArray<IdentityAccount> ();
    }

    public static string directory () {
        return Path.build_filename (Environment.get_user_data_dir (), "letter", "identity");
    }

    public static string path () {
        return Path.build_filename (directory (), "accounts.json");
    }

    public static IdentityCatalog load () throws Error {
        var catalog = new IdentityCatalog ();
        var file = File.new_for_path (path ());
        if (!file.query_exists ())
            return catalog;

        uint8[] data;
        file.load_contents (null, out data, null);
        var parser = new Json.Parser ();
        parser.load_from_data ((string) data, data.length);
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
            throw new IOError.INVALID_DATA ("Identity catalog is not a JSON object");

        var obj = root.get_object ();
        if (!obj.has_member ("accounts"))
            return catalog;

        foreach (var node in obj.get_array_member ("accounts").get_elements ()) {
            if (node.get_node_type () != Json.NodeType.OBJECT)
                continue;
            var o = node.get_object ();
            var acc = new IdentityAccount () {
                id = o.get_string_member ("id"),
                kind = o.has_member ("kind") ? o.get_string_member ("kind") : "imap",
                auth_method = o.has_member ("auth_method")
                    ? o.get_string_member ("auth_method") : "password",
                display_name = o.get_string_member ("display_name"),
                sender_name = o.has_member ("sender_name")
                    ? o.get_string_member ("sender_name") : null,
                email = o.get_string_member ("email"),
                username = o.has_member ("username")
                    ? o.get_string_member ("username")
                    : o.get_string_member ("email"),
                imap_host = o.get_string_member ("imap_host"),
                imap_port = o.has_member ("imap_port")
                    ? (uint) o.get_int_member ("imap_port") : 993,
                imap_tls = !o.has_member ("imap_tls") || o.get_boolean_member ("imap_tls"),
                smtp_host = o.has_member ("smtp_host") ? o.get_string_member ("smtp_host") : null,
                smtp_port = o.has_member ("smtp_port")
                    ? (uint) o.get_int_member ("smtp_port") : 465,
                smtp_tls = !o.has_member ("smtp_tls") || o.get_boolean_member ("smtp_tls"),
                enabled = !o.has_member ("enabled") || o.get_boolean_member ("enabled"),
            };
            catalog.accounts.add (acc);
        }
        return catalog;
    }

    public void save () throws Error {
        var dir = File.new_for_path (directory ());
        try {
            dir.make_directory_with_parents ();
        } catch (Error e) {
            if (!(e is IOError.EXISTS))
                throw e;
        }

        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("version");
        builder.add_int_value (FORMAT_VERSION);
        builder.set_member_name ("accounts");
        builder.begin_array ();
        for (uint i = 0; i < this.accounts.length; i++) {
            var a = this.accounts[i];
            builder.begin_object ();
            builder.set_member_name ("id");
            builder.add_string_value (a.id);
            builder.set_member_name ("kind");
            builder.add_string_value (a.kind);
            builder.set_member_name ("auth_method");
            builder.add_string_value (a.auth_method ?? "password");
            builder.set_member_name ("display_name");
            builder.add_string_value (a.display_name);
            if (a.sender_name != null && a.sender_name.length > 0) {
                builder.set_member_name ("sender_name");
                builder.add_string_value (a.sender_name);
            }
            builder.set_member_name ("email");
            builder.add_string_value (a.email);
            builder.set_member_name ("username");
            builder.add_string_value (a.username);
            builder.set_member_name ("imap_host");
            builder.add_string_value (a.imap_host);
            builder.set_member_name ("imap_port");
            builder.add_int_value (a.imap_port);
            builder.set_member_name ("imap_tls");
            builder.add_boolean_value (a.imap_tls);
            if (a.smtp_host != null) {
                builder.set_member_name ("smtp_host");
                builder.add_string_value (a.smtp_host);
            }
            builder.set_member_name ("smtp_port");
            builder.add_int_value (a.smtp_port);
            builder.set_member_name ("smtp_tls");
            builder.add_boolean_value (a.smtp_tls);
            builder.set_member_name ("enabled");
            builder.add_boolean_value (a.enabled);
            builder.end_object ();
        }
        builder.end_array ();
        builder.end_object ();

        var gen = new Json.Generator ();
        gen.set_root (builder.get_root ());
        gen.pretty = true;
        gen.indent = 2;
        gen.to_file (path ());
    }

    public IdentityAccount add_imap (
        string email,
        string display_name,
        string username,
        string imap_host,
        uint imap_port,
        bool imap_tls,
        string? smtp_host,
        uint smtp_port,
        bool smtp_tls
    ) {
        var acc = new IdentityAccount () {
            id = Uuid.string_random (),
            kind = "imap",
            auth_method = "password",
            email = email,
            display_name = display_name,
            sender_name = display_name,
            username = username,
            imap_host = imap_host,
            imap_port = imap_port,
            imap_tls = imap_tls,
            smtp_host = smtp_host,
            smtp_port = smtp_port,
            smtp_tls = smtp_tls,
            enabled = true,
        };
        this.accounts.add (acc);
        return acc;
    }

    public IdentityAccount add_oauth_google (string email, string display_name) {
        var acc = new IdentityAccount () {
            id = Uuid.string_random (),
            kind = "google",
            auth_method = "oauth2",
            email = email,
            display_name = display_name,
            sender_name = display_name,
            username = email,
            imap_host = "imap.gmail.com",
            imap_port = 993,
            imap_tls = true,
            smtp_host = "smtp.gmail.com",
            smtp_port = 465,
            smtp_tls = true,
            enabled = true,
        };
        this.accounts.add (acc);
        return acc;
    }

    public IdentityAccount add_oauth_microsoft (string email, string display_name) {
        var acc = new IdentityAccount () {
            id = Uuid.string_random (),
            kind = "microsoft",
            auth_method = "oauth2",
            email = email,
            display_name = display_name,
            sender_name = display_name,
            username = email,
            imap_host = "outlook.office365.com",
            imap_port = 993,
            imap_tls = true,
            smtp_host = "smtp.office365.com",
            smtp_port = 587,
            smtp_tls = true,
            enabled = true,
        };
        this.accounts.add (acc);
        return acc;
    }

    public bool remove_by_id (string id) {
        for (uint i = 0; i < this.accounts.length; i++) {
            if (this.accounts[i].id == id) {
                this.accounts.remove_index (i);
                return true;
            }
        }
        return false;
    }

    /**
     * Remove catalog row + libsecret. Optionally wipe Letter’s on-disk library
     * for this Identity id (IMAP engine bodies, header lists, folder tree).
     * Server mail is never deleted.
     */
    public static void remove_account (string account_id, bool wipe_local_library) throws Error {
        var catalog = load ();
        if (!catalog.remove_by_id (account_id)) {
            throw new IOError.NOT_FOUND (
                _("No Letter Identity account “%s”.").printf (account_id)
            );
        }
        catalog.save ();

        try {
            IdentitySecrets.clear_password (account_id);
        } catch (Error e) {
            warning ("Clear Identity password: %s", e.message);
        }
        try {
            IdentitySecrets.clear_oauth_tokens (account_id);
        } catch (Error e) {
            warning ("Clear Identity OAuth: %s", e.message);
        }

        if (wipe_local_library)
            wipe_local_library_files (account_id);
    }

    public static string engine_imap_dir (string account_id) {
        return Path.build_filename (
            Environment.get_user_data_dir (),
            "letter",
            "engine",
            "imap",
            account_id
        );
    }

    public static uint64 local_library_bytes (string account_id) {
        var headers = Path.build_filename (
            MailSession.header_list_cache_dir (),
            Checksum.compute_for_string (ChecksumType.SHA256, account_id)
        );
        uint64 total = directory_size (engine_imap_dir (account_id))
            + directory_size (headers);
        var tree = MailSession.folder_tree_cache_file (account_id);
        if (FileUtils.test (tree, FileTest.IS_REGULAR)) {
            try {
                total += File.new_for_path (tree).query_info (
                    FileAttribute.STANDARD_SIZE,
                    FileQueryInfoFlags.NONE
                ).get_size ();
            } catch (Error e) {
            }
        }
        return total;
    }

    public static void wipe_local_library_files (string account_id) {
        delete_tree_quiet (engine_imap_dir (account_id));
        MailSession.delete_header_list_cache (account_id);
        MailSession.delete_folder_tree_cache (account_id);
        /* Prefetch / misc under cache/letter/mail/<id> if present. */
        delete_tree_quiet (Path.build_filename (
            Environment.get_user_cache_dir (), "letter", "mail", account_id
        ));
        delete_tree_quiet (Path.build_filename (
            Environment.get_user_data_dir (), "letter", "mail", account_id
        ));
    }

    private static uint64 directory_size (string path) {
        if (path.length == 0 || !FileUtils.test (path, FileTest.IS_DIR))
            return 0;
        uint64 total = 0;
        try {
            var dir = File.new_for_path (path);
            var enumerator = dir.enumerate_children (
                "standard::name,standard::type,standard::size",
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS
            );
            FileInfo? info = null;
            while ((info = enumerator.next_file ()) != null) {
                if (info.get_file_type () == FileType.DIRECTORY)
                    total += directory_size (Path.build_filename (path, info.get_name ()));
                else
                    total += info.get_size ();
            }
        } catch (Error e) {
        }
        return total;
    }

    private static void delete_tree_quiet (string path) {
        try {
            var file = File.new_for_path (path);
            if (!file.query_exists ())
                return;
            delete_file_recursive (file);
        } catch (Error e) {
            warning ("Identity wipe %s: %s", path, e.message);
        }
    }

    private static void delete_file_recursive (File file) throws Error {
        if (file.query_file_type (FileQueryInfoFlags.NOFOLLOW_SYMLINKS) == FileType.DIRECTORY) {
            var enumerator = file.enumerate_children (
                FileAttribute.STANDARD_NAME,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS
            );
            FileInfo? info = null;
            while ((info = enumerator.next_file ()) != null)
                delete_file_recursive (enumerator.get_child (info));
        }
        file.delete ();
    }
}
