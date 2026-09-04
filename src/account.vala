public enum Mail.AccountKind {
    IMAP,
    GOOGLE,
    MICROSOFT,
    EXCHANGE,
    LOCAL,
    OTHER;

    public string label () {
        switch (this) {
            case IMAP:
                return _("IMAP");
            case GOOGLE:
                return _("Google");
            case MICROSOFT:
                return _("Microsoft 365");
            case EXCHANGE:
                return _("Exchange");
            case LOCAL:
                return _("On this computer");
            default:
                return _("Other");
        }
    }

    public string icon_name () {
        switch (this) {
            case GOOGLE:
                return "goa-account-google";
            case MICROSOFT:
                return "goa-account-ms365";
            case EXCHANGE:
                return "goa-account-exchange";
            case LOCAL:
                return "drive-harddisk-symbolic";
            default:
                return "goa-account";
        }
    }

    public static AccountKind from_provider (string? goa_type, string? backend_name) {
        var goa = (goa_type ?? "").down ();
        var backend = (backend_name ?? "").down ();

        if (goa.contains ("google") || backend.contains ("google") || backend == "gmail")
            return GOOGLE;

        if (goa.contains ("ms_graph") || goa.contains ("microsoft") || goa.contains ("windows_live")
            || goa.contains ("outlook") || backend.contains ("office")
            || backend.contains ("microsoft") || backend.contains ("graph"))
            return MICROSOFT;

        if (goa.contains ("exchange") || backend == "ews" || backend.contains ("exchange"))
            return EXCHANGE;

        if (backend == "maildir" || backend == "mbox" || backend == "local")
            return LOCAL;

        if (goa.contains ("imap") || backend == "imapx" || backend == "imap")
            return IMAP;

        return OTHER;
    }
}

public class Mail.Account : Object {
    public string uid { get; set; }
    public string display_name { get; set; }
    public string? email { get; set; }
    public AccountKind kind { get; set; }
    public bool has_mail { get; set; }
    public bool has_calendar { get; set; }
    public bool has_contacts { get; set; }
    public string? backend_name { get; set; }
    public string? goa_id { get; set; }
    public string? source_uid { get; set; }
    public string? provider_icon { get; set; }
    public bool enabled { get; set; default = true; }

    public string signature_key {
        owned get {
            if (this.goa_id != null && this.goa_id.length > 0)
                return this.goa_id;
            if (this.source_uid != null && this.source_uid.length > 0)
                return this.source_uid;
            if (this.uid != null && this.uid.length > 0)
                return this.uid;
            return this.email ?? "";
        }
    }

    public string subtitle {
        owned get {
            if (this.kind == AccountKind.LOCAL)
                return "";

            if (this.email != null && this.email == this.display_name)
                return this.kind.label ();

            if (this.email != null)
                return this.email;

            return this.kind.label ();
        }
    }
}

public class Mail.Folder : Object {
    public const uint TYPE_MASK = 0x3F << 10;
    public const uint FLAG_VIRTUAL = 1 << 5;
    public const uint FLAG_SYSTEM = 1 << 6;
    public const uint FLAG_VTRASH = 1 << 7;
    public const uint FLAG_NOINFERIORS = 1 << 1;
    public const string BOOKMARKS_PATH = ":bookmarks";

    public string name { get; set; }
    public string full_name { get; set; }
    public int unread { get; set; }
    public int total { get; set; }
    public uint indent { get; set; }
    public uint flags { get; set; }
    public bool watch_new_mail { get; set; }
    public bool has_children { get; set; }

    public FolderKind kind {
        get {
            return FolderKind.from_flags (this.flags, this.name, this.full_name);
        }
    }

    public bool hidden {
        get {
            if (this.kind == FolderKind.INBOX)
                return false;

            if ((this.flags & FLAG_VIRTUAL) != 0
                || (this.flags & FLAG_VTRASH) != 0)
                return true;

            switch (this.kind) {
                case FolderKind.OUTBOX:
                    return this.total <= 0 && this.unread <= 0;
                case FolderKind.CONTACTS:
                case FolderKind.EVENTS:
                case FolderKind.MEMOS:
                case FolderKind.TASKS:
                case FolderKind.SYSTEM:
                    return true;
                default:
                    return false;
            }
        }
    }

    public int badge_count {
        get {
            if (this.badge_shows_total)
                return this.total > 0 ? this.total : 0;
            if (this.unread > 0)
                return this.unread;
            return 0;
        }
    }

    public bool badge_shows_total {
        get {
            switch (this.kind) {
                case FolderKind.DRAFTS:
                case FolderKind.OUTBOX:
                case FolderKind.BOOKMARKS:
                case FolderKind.STARRED:
                case FolderKind.IMPORTANT:
                    return true;
                default:
                    return false;
            }
        }
    }

    public int sort_rank {
        get {
            switch (this.kind) {
                case FolderKind.INBOX:
                    return 0;
                case FolderKind.BOOKMARKS:
                    return 1;
                case FolderKind.DRAFTS:
                    return 2;
                case FolderKind.SENT:
                    return 3;
                case FolderKind.JUNK:
                    return 4;
                case FolderKind.TRASH:
                    return 5;
                case FolderKind.ARCHIVE:
                case FolderKind.ALL:
                    return 6;
                case FolderKind.IMPORTANT:
                    return 10;
                case FolderKind.STARRED:
                    return 11;
                case FolderKind.OUTBOX:
                    return 80;
                case FolderKind.SYSTEM:
                    return 90;
                default:
                    if (this.is_gmail_namespace)
                        return 40;
                    return 50;
            }
        }
    }

    public string icon_name {
        get {
            switch (this.kind) {
                case FolderKind.INBOX:
                    return "mail-unread-symbolic";
                case FolderKind.BOOKMARKS:
                    return "user-bookmarks-symbolic";
                case FolderKind.DRAFTS:
                    return "document-edit-symbolic";
                case FolderKind.SENT:
                    return "mail-send-symbolic";
                case FolderKind.TRASH:
                    return "user-trash-symbolic";
                case FolderKind.ARCHIVE:
                    return "package-x-generic-symbolic";
                case FolderKind.ALL:
                    return "folder-documents-symbolic";
                case FolderKind.STARRED:
                    return "starred-symbolic";
                case FolderKind.IMPORTANT:
                    return "mail-mark-important-symbolic";
                case FolderKind.JUNK:
                    return "mail-mark-junk-symbolic";
                case FolderKind.OUTBOX:
                    return "mail-send-receive-symbolic";
                default:
                    return "folder-symbolic";
            }
        }
    }

    public bool is_gmail_namespace {
        get {
            return FolderKind.is_gmail_namespace_name (this.name, this.full_name);
        }
    }

    public bool is_gmail_important {
        get {
            return FolderKind.matches_names (this.name, this.full_name, {
                "important", "importanti"
            });
        }
    }

    public bool is_gmail_starred {
        get {
            return FolderKind.matches_names (this.name, this.full_name, {
                "starred", "speciali"
            });
        }
    }

    public bool is_archive_mailbox {
        get {
            return this.kind == FolderKind.ARCHIVE || this.kind == FolderKind.ALL;
        }
    }

    public string leaf_name {
        owned get {
            var slash = this.full_name.last_index_of_char ('/');
            if (slash < 0 || slash + 1 >= this.full_name.length)
                return this.name;
            return this.full_name.substring (slash + 1);
        }
    }

    public string parent_full_name {
        owned get {
            var slash = this.full_name.last_index_of_char ('/');
            if (slash < 0)
                return "";
            return this.full_name.substring (0, slash);
        }
    }

    public bool is_virtual_view {
        get {
            return this.kind == FolderKind.BOOKMARKS;
        }
    }

    public bool is_server_required {
        get {
            if ((this.flags & FLAG_SYSTEM) != 0
                || (this.flags & FLAG_VIRTUAL) != 0
                || (this.flags & FLAG_VTRASH) != 0)
                return true;

            switch (this.kind) {
                case FolderKind.NORMAL:
                    return false;
                default:
                    return true;
            }
        }
    }

    public bool can_create_children {
        get {
            if ((this.flags & FLAG_VIRTUAL) != 0)
                return false;
            if (this.is_virtual_view)
                return false;
            if ((this.flags & FLAG_NOINFERIORS) != 0)
                return false;
            if (this.kind == FolderKind.OUTBOX)
                return false;
            return true;
        }
    }

    public bool is_inside (Folder ancestor) {
        return this.full_name.has_prefix (ancestor.full_name + "/");
    }
}

public enum Mail.FolderKind {
    NORMAL,
    INBOX,
    BOOKMARKS,
    DRAFTS,
    SENT,
    TRASH,
    ARCHIVE,
    JUNK,
    OUTBOX,
    CONTACTS,
    EVENTS,
    MEMOS,
    TASKS,
    ALL,
    STARRED,
    IMPORTANT,
    SYSTEM;

    public static FolderKind from_flags (uint flags, string? name, string? full_name) {
        if (full_name == Folder.BOOKMARKS_PATH)
            return BOOKMARKS;

        uint type = flags & Folder.TYPE_MASK;
        if (type == (1 << 10))
            return INBOX;
        if (type == (12 << 10))
            return DRAFTS;
        if (type == (5 << 10))
            return SENT;
        if (type == (3 << 10))
            return TRASH;
        if (type == (11 << 10))
            return is_gmail_all_mail (name, full_name) ? ALL : ARCHIVE;
        if (type == (4 << 10))
            return JUNK;
        if (type == (2 << 10))
            return OUTBOX;
        if (type == (6 << 10))
            return CONTACTS;
        if (type == (7 << 10))
            return EVENTS;
        if (type == (8 << 10))
            return MEMOS;
        if (type == (9 << 10))
            return TASKS;
        if (type == (10 << 10))
            return ALL;

        return from_name (name, full_name);
    }

    public static bool is_gmail_namespace_name (string? name, string? full_name) {
        return matches_names (name, full_name, { "[gmail]", "[google mail]" });
    }

    public static bool matches_names (string? name, string? full_name, string[] names) {
        var leaf = leaf_name (full_name ?? name ?? "").down ();
        var label = (name ?? "").down ();
        return matches (label, leaf, names);
    }

    private static bool is_gmail_all_mail (string? name, string? full_name) {
        if (matches_names (name, full_name, {
            "all mail", "allmail", "tutti i messaggi", "tutte le email"
        }))
            return true;

        if (!is_under_gmail (full_name))
            return false;

        return matches_names (name, full_name, { "archive", "archivio" });
    }

    private static bool is_under_gmail (string? full_name) {
        var path = (full_name ?? "").down ();
        return path.has_prefix ("[gmail]/") || path.has_prefix ("[google mail]/");
    }

    private static FolderKind from_name (string? name, string? full_name) {
        var leaf = leaf_name (full_name ?? name ?? "").down ();
        var label = (name ?? "").down ();

        if (matches (label, leaf, { "inbox", "posta in arrivo" }))
            return INBOX;
        if (matches (label, leaf, { "drafts", "bozze" }))
            return DRAFTS;
        if (matches (label, leaf, { "sent", "sent items", "sent mail", "posta inviata", "inviata" }))
            return SENT;
        if (matches (label, leaf, { "trash", "deleted items", "deleted", "posta eliminata", "cestino", "bin" }))
            return TRASH;
        if (matches (label, leaf, { "important", "importanti" }))
            return IMPORTANT;
        if (matches (label, leaf, { "starred", "speciali" }))
            return STARRED;
        if (is_gmail_all_mail (name, full_name) || matches (label, leaf, {
            "all mail", "allmail", "tutti i messaggi", "tutte le email"
        }))
            return ALL;
        if (matches (label, leaf, { "archive", "archivio" }))
            return ARCHIVE;
        if (matches (label, leaf, { "junk", "junk email", "spam", "posta indesiderata", "indesiderata" }))
            return JUNK;
        if (matches (label, leaf, { "outbox", "posta in uscita" }))
            return OUTBOX;
        if (matches (label, leaf, {
            "sync issues", "problemi di sincronizzazione",
            "conflicts", "conflitti", "local failures", "server failures",
            "errori del server", "errori in locale", "local failure",
            "rss", "rss feeds", "rss subscriptions", "sottoscrizioni rss",
            "conversation history", "cronologia delle conversazioni",
            "search folders", "cartelle di ricerca"
        }))
            return SYSTEM;

        return NORMAL;
    }

    private static string leaf_name (string path) {
        var slash = path.last_index_of_char ('/');
        if (slash >= 0 && slash + 1 < path.length)
            return path.substring (slash + 1);
        return path;
    }

    private static bool matches (string label, string leaf, string[] names) {
        foreach (var candidate in names) {
            if (label == candidate || leaf == candidate)
                return true;
        }
        return false;
    }
}

public class Mail.Message : Object {
    public string uid { get; set; }
    public string subject { get; set; }
    public string from { get; set; }
    public string to { get; set; }
    public string cc { get; set; default = ""; }
    public string? from_blob { get; set; }
    public string? to_blob { get; set; }
    public string list_address { get; set; }
    public int64 date { get; set; }
    public bool seen { get; set; }
    public bool flagged { get; set; }
    public bool important { get; set; }
    public bool has_attachment { get; set; }
    public string? preview { get; set; }
    public string? folder_name { get; set; }
    public string? folder_full_name { get; set; }
    public bool show_folder { get; set; }
    public bool outgoing { get; set; }
    public uint64 msgid_hash { get; set; }
    public uint64[] msgid_refs { get; set; }
    public string? conversation_key { get; set; }
    public string? search_blob { get; set; }
    public bool local_only { get; set; }

    public bool is_placeholder {
        get {
            return this.local_only
                || (this.uid != null && this.uid.has_prefix ("local-sent-"))
                || (this.uid != null && this.uid.has_prefix ("local-draft-"));
        }
    }
}
