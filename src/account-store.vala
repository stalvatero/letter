public class Mail.AccountStore : Object {
    public ListStore items { get; default = new ListStore (typeof (Account)); }
    public uint calendar_count { get; private set; }
    public uint contact_count { get; private set; }
    public bool loaded { get; private set; }
    public string? error_message { get; private set; }

    public E.SourceRegistry? registry { get; private set; }
    public Goa.Client? goa { get; private set; }

    public signal void changed ();

    private bool watching = false;

    public async void load () {
        this.error_message = null;

        try {
            this.registry = yield new E.SourceRegistry (null);
        } catch (Error e) {
            warning ("Could not connect to Evolution Data Server: %s", e.message);
            this.error_message = e.message;
        }

        try {
            this.goa = yield new Goa.Client (null);
        } catch (Error e) {
            warning ("Could not connect to GNOME Online Accounts: %s", e.message);
            if (this.error_message == null)
                this.error_message = e.message;
        }

        rebuild ();
        this.loaded = true;
        changed ();

        if (this.watching)
            return;

        this.watching = true;

        if (this.registry != null) {
            this.registry.source_added.connect (() => rebuild_and_notify ());
            this.registry.source_removed.connect (() => rebuild_and_notify ());
            this.registry.source_changed.connect (() => rebuild_and_notify ());
            this.registry.source_enabled.connect (() => rebuild_and_notify ());
            this.registry.source_disabled.connect (() => rebuild_and_notify ());
        }

        if (this.goa != null) {
            this.goa.account_added.connect (() => rebuild_and_notify ());
            this.goa.account_removed.connect (() => rebuild_and_notify ());
            this.goa.account_changed.connect (() => rebuild_and_notify ());
        }
    }

    private void rebuild_and_notify () {
        rebuild ();
        changed ();
    }

    private void rebuild () {
        this.items.remove_all ();
        this.calendar_count = 0;
        this.contact_count = 0;

        if (this.registry != null) {
            foreach (var source in this.registry.list_enabled (E.SOURCE_EXTENSION_CALENDAR)) {
                if (!is_builtin (source))
                    this.calendar_count++;
            }

            foreach (var source in this.registry.list_enabled (E.SOURCE_EXTENSION_ADDRESS_BOOK)) {
                if (!is_builtin (source))
                    this.contact_count++;
            }
        }

        if (this.goa != null) {
            foreach (var object in this.goa.get_accounts ())
                add_or_merge (account_from_goa (object));
        }

        if (this.registry != null) {
            foreach (var source in this.registry.list_sources (E.SOURCE_EXTENSION_MAIL_ACCOUNT)) {
                if (source.get_uid () == "vfolder")
                    continue;
                merge_into_existing (account_from_source (source));
            }
        }
    }

    private void add_or_merge (Account? incoming) {
        if (incoming == null)
            return;

        for (uint i = 0; i < this.items.get_n_items (); i++) {
            var existing = (Account) this.items.get_item (i);
            if (same_account (existing, incoming)) {
                merge (existing, incoming);
                return;
            }
        }

        this.items.append (incoming);
    }

    private void merge_into_existing (Account? incoming) {
        if (incoming == null)
            return;

        for (uint i = 0; i < this.items.get_n_items (); i++) {
            var existing = (Account) this.items.get_item (i);
            if (same_account (existing, incoming)) {
                merge (existing, incoming);
                return;
            }
        }
    }

    private static bool same_account (Account a, Account b) {
        if (a.source_uid != null && a.source_uid == b.source_uid)
            return true;

        if (a.goa_id != null && b.goa_id != null && a.goa_id == b.goa_id)
            return true;

        if (a.email != null && b.goa_id != null && a.email.down () == b.goa_id.down ())
            return true;
        if (b.email != null && a.goa_id != null && b.email.down () == a.goa_id.down ())
            return true;

        if (a.email != null && b.email != null && a.email.contains ("@") && b.email.contains ("@")
            && a.email.down () == b.email.down ())
            return true;

        return false;
    }

    private static void merge (Account into, Account from) {
        if (into.email == null)
            into.email = from.email;

        if (from.provider_icon != null) {
            into.has_mail = from.has_mail;
            into.has_calendar = from.has_calendar;
            into.has_contacts = from.has_contacts;
            into.goa_id = from.goa_id;
            into.kind = from.kind;
            into.provider_icon = from.provider_icon;
        } else if (into.provider_icon == null) {
            if (from.has_mail)
                into.has_mail = true;
            if (from.has_calendar)
                into.has_calendar = true;
            if (from.has_contacts)
                into.has_contacts = true;
        }

        if (into.source_uid == null)
            into.source_uid = from.source_uid;

        if (into.goa_id == null)
            into.goa_id = from.goa_id;

        if (into.backend_name == null)
            into.backend_name = from.backend_name;

        if (into.kind == AccountKind.OTHER || into.kind == AccountKind.IMAP)
            into.kind = from.kind;

        if (into.display_name == null || into.display_name == into.email) {
            if (from.display_name != null && from.display_name != from.email)
                into.display_name = from.display_name;
        }
    }

    private Account? account_from_source (E.Source source) {
        var mail_account = (E.SourceMailAccount) source.get_extension (E.SOURCE_EXTENSION_MAIL_ACCOUNT);
        var backend_name = mail_account.dup_backend_name ();
        if (mail_account.get_builtin () || backend_name == "maildir"
            || backend_name == "mbox" || backend_name == "local")
            return null;

        var account = new Account () {
            uid = source.get_uid (),
            source_uid = source.get_uid (),
            display_name = source.dup_display_name (),
            enabled = source.get_enabled (),
            has_mail = source.get_enabled (),
            backend_name = backend_name,
        };

        var identity_uid = mail_account.dup_identity_uid ();
        if (identity_uid != null && this.registry != null) {
            var identity_source = this.registry.ref_source (identity_uid);
            if (identity_source != null && identity_source.has_extension (E.SOURCE_EXTENSION_MAIL_IDENTITY)) {
                var identity = (E.SourceMailIdentity) identity_source.get_extension (E.SOURCE_EXTENSION_MAIL_IDENTITY);
                account.email = identity.dup_address ();
                var name = identity.dup_name ();
                if (name != null && name.length > 0)
                    account.display_name = name;
            }
        }

        string? goa_type = null;
        apply_goa_extension (source, account);
        var parent_uid = source.get_parent ();
        if (parent_uid != null && this.registry != null) {
            var parent = this.registry.ref_source (parent_uid);
            if (parent != null) {
                apply_goa_extension (parent, account);
                if (parent.has_extension (E.SOURCE_EXTENSION_COLLECTION)) {
                    var collection = (E.SourceCollection) parent.get_extension (E.SOURCE_EXTENSION_COLLECTION);
                    account.has_calendar = collection.get_calendar_enabled ();
                    account.has_contacts = collection.get_contacts_enabled ();
                    goa_type = parent.dup_display_name ();
                    var identity = collection.dup_identity ();
                    if (identity != null && account.goa_id == null)
                        account.goa_id = identity;
                }
            }
        }

        account.kind = AccountKind.from_provider (goa_type, account.backend_name);
        return account;
    }

    private Account? account_from_goa (Goa.Object object) {
        var goa_account = object.get_account ();
        if (goa_account == null)
            return null;

        var mail = object.get_mail ();
        if (mail == null && !goa_is_mail_provider (goa_account.provider_type))
            return null;

        var email = (mail != null ? mail.email_address : null) ?? goa_account.identity;
        var presentation = goa_account.presentation_identity;
        var display = presentation;
        if (display == null || display.length == 0 || (email != null && display == email))
            display = email ?? AccountKind.from_provider (goa_account.provider_type, null).label ();
        var account = new Account () {
            uid = goa_account.id,
            goa_id = goa_account.id,
            display_name = display,
            email = email,
            kind = AccountKind.from_provider (goa_account.provider_type, null),
            provider_icon = goa_account.provider_icon,
            has_mail = mail != null && !goa_account.mail_disabled,
            has_calendar = object.get_calendar () != null && !goa_account.calendar_disabled,
            has_contacts = object.get_contacts () != null && !goa_account.contacts_disabled,
            enabled = !goa_account.attention_needed,
        };

        return account;
    }

    private void apply_goa_extension (E.Source source, Account account) {
        if (!source.has_extension (E.SOURCE_EXTENSION_GOA))
            return;

        var ext = (E.SourceGoa) source.get_extension (E.SOURCE_EXTENSION_GOA);
        var id = ext.dup_account_id ();
        if (id != null && id.length > 0)
            account.goa_id = id;
        var address = ext.dup_address ();
        if (account.email == null && address != null && address.length > 0)
            account.email = address;
        var name = ext.dup_name ();
        if (name != null && name.length > 0 && (account.display_name == null || account.display_name == account.email))
            account.display_name = name;
    }

    private static bool goa_is_mail_provider (string? provider_type) {
        var type = (provider_type ?? "").down ();
        return type == "google"
            || type == "ms_graph"
            || type == "exchange"
            || type == "imap_smtp"
            || type == "windows_live"
            || type.contains ("microsoft");
    }

    private static bool is_builtin (E.Source source) {
        if (source.has_extension (E.SOURCE_EXTENSION_MAIL_ACCOUNT)) {
            var mail = (E.SourceMailAccount) source.get_extension (E.SOURCE_EXTENSION_MAIL_ACCOUNT);
            return mail.get_builtin ();
        }

        return false;
    }
}
