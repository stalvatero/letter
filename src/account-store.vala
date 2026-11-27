/**
 * Aggregates AccountSource adapters into the UI ListStore.
 * Phase 1: Letter Identity first, then optional GoaEds.
 */
public class Mail.AccountStore : Object {
    public ListStore items { get; default = new ListStore (typeof (Account)); }
    public uint calendar_count { get; private set; }
    public uint contact_count { get; private set; }
    public bool loaded { get; private set; }
    public string? error_message { get; private set; }
    public bool using_goa { get; private set; }

    public E.SourceRegistry? registry {
        get {
            for (uint i = 0; i < this.sources.length; i++) {
                if (this.sources[i].registry != null)
                    return this.sources[i].registry;
            }
            return null;
        }
    }

    /** GOA client when the optional GOA/EDS source is active (rail avatars). */
    public Goa.Client? goa {
        get {
            for (uint i = 0; i < this.sources.length; i++) {
                var src = this.sources[i] as GoaEdsAccountSource;
                if (src != null)
                    return src.goa;
            }
            return null;
        }
    }

    public signal void changed ();

    private GenericArray<AccountSource> sources;
    private Settings? settings;
    private bool loading = false;

    public AccountStore (Settings? settings = null) {
        this.settings = settings;
        this.sources = new GenericArray<AccountSource> ();
        /* Letter Identity first so in-app accounts appear without GOA;
         * GOA/EDS remains optional sibling and can enrich matching rows. */
        add_source (new LetterIdentityAccountSource ());
        sync_goa_source ();
    }

    /** Env LETTER_SKIP_GOA=1 always wins; else GSettings use-goa-accounts. */
    public bool goa_preference_enabled () {
        var skip = Environment.get_variable ("LETTER_SKIP_GOA");
        if (skip != null && skip == "1")
            return false;
        if (this.settings != null)
            return this.settings.get_boolean ("use-goa-accounts");
        return true;
    }

    /**
     * Toggle GOA/EDS as an account source. Persists to GSettings when set.
     * Caller should rebind the mail backend after accounts reload.
     */
    public async void set_use_goa_accounts (bool enabled) {
        if (this.settings != null) {
            this.settings.set_boolean ("use-goa-accounts", enabled);
            this.settings.set_boolean ("goa-accounts-prompted", true);
        }
        var had = this.using_goa;
        sync_goa_source ();
        if (this.using_goa && !had) {
            for (uint i = 0; i < this.sources.length; i++) {
                if (this.sources[i] is GoaEdsAccountSource)
                    yield this.sources[i].load ();
            }
        }
        this.loaded = true;
        rebuild_and_notify ();
    }

    private void sync_goa_source () {
        var want = goa_preference_enabled ();
        GoaEdsAccountSource? goa = null;
        for (uint i = 0; i < this.sources.length; i++) {
            goa = this.sources[i] as GoaEdsAccountSource;
            if (goa != null)
                break;
        }
        if (want && goa == null) {
            add_source (new GoaEdsAccountSource ());
            this.using_goa = true;
            message ("AccountStore: GOA/EDS source enabled");
        } else if (!want && goa != null) {
            for (uint i = 0; i < this.sources.length; i++) {
                if (this.sources[i] == goa) {
                    this.sources.remove_index (i);
                    break;
                }
            }
            this.using_goa = false;
            message ("AccountStore: GOA/EDS source disabled");
        } else {
            this.using_goa = want && goa != null;
            if (!want) {
                var skip = Environment.get_variable ("LETTER_SKIP_GOA");
                if (skip != null && skip == "1")
                    message ("AccountStore: LETTER_SKIP_GOA=1 — GOA/EDS source disabled");
                else
                    message ("AccountStore: use-goa-accounts=false — GOA/EDS source disabled");
            }
        }
    }

    public void add_source (AccountSource source) {
        this.sources.add (source);
        source.changed.connect (rebuild_and_notify);
    }

    /** After the Identity wizard (or CLI) writes accounts.json + libsecret. */
    public void reload_identity () {
        for (uint i = 0; i < this.sources.length; i++) {
            var src = this.sources[i] as LetterIdentityAccountSource;
            if (src != null)
                src.reload_from_disk ();
        }
    }

    public bool has_mail_accounts () {
        for (uint i = 0; i < this.items.get_n_items (); i++) {
            var account = this.items.get_item (i) as Account;
            if (account == null || !account.has_mail)
                continue;
            if (account.kind == AccountKind.LOCAL)
                continue;
            return true;
        }
        return false;
    }

    public async void load () {
        while (this.loading) {
            Idle.add (load.callback);
            yield;
        }
        if (this.loaded)
            return;

        this.loading = true;
        this.error_message = null;

        try {
            for (uint i = 0; i < this.sources.length; i++)
                yield this.sources[i].load ();

            collect_errors ();
            rebuild ();
            this.loaded = true;
            changed ();
        } finally {
            this.loading = false;
        }
    }

    private void collect_errors () {
        this.error_message = null;
        for (uint i = 0; i < this.sources.length; i++) {
            var err = this.sources[i].error_message;
            if (err != null && err.length > 0) {
                this.error_message = err;
                break;
            }
        }
    }

    private void rebuild_and_notify () {
        collect_errors ();
        rebuild ();
        changed ();
    }

    private void rebuild () {
        this.items.remove_all ();
        this.calendar_count = 0;
        this.contact_count = 0;

        for (uint i = 0; i < this.sources.length; i++) {
            var source = this.sources[i];
            this.calendar_count += source.calendar_count;
            this.contact_count += source.contact_count;

            var primary = source.primary_accounts ();
            for (uint j = 0; j < primary.length; j++)
                add_or_merge (primary[j]);

            var enrichment = source.enrichment_accounts ();
            for (uint j = 0; j < enrichment.length; j++)
                merge_into_existing (enrichment[j]);
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

        /* Keep Letter Identity as the mail engine when the same address
         * exists in GOA — RoutingMailBackend keys off letter-imap / letter-graph. */
        var identity = into.is_letter_identity || from.is_letter_identity;

        if (from.provider_icon != null) {
            into.has_mail = from.has_mail || into.has_mail;
            into.has_calendar = from.has_calendar || into.has_calendar;
            into.has_contacts = from.has_contacts || into.has_contacts;
            if (from.goa_id != null)
                into.goa_id = from.goa_id;
            if (!identity)
                into.kind = from.kind;
            else if (into.kind == AccountKind.OTHER || into.kind == AccountKind.IMAP)
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
        else if (from.is_letter_identity && from.source_uid != null)
            into.source_uid = from.source_uid;

        if (into.goa_id == null)
            into.goa_id = from.goa_id;

        if (identity) {
            /* Prefer the Identity row’s engine (imap vs graph). */
            if (from.is_letter_identity && from.backend_name != null)
                into.backend_name = from.backend_name;
            else if (into.is_letter_identity && into.backend_name != null) {
                /* keep */
            } else {
                into.backend_name = "letter-imap";
            }
        } else if (into.backend_name == null) {
            into.backend_name = from.backend_name;
        }

        if (!identity && (into.kind == AccountKind.OTHER || into.kind == AccountKind.IMAP))
            into.kind = from.kind;

        if (into.display_name == null || into.display_name == into.email) {
            if (from.display_name != null && from.display_name != from.email)
                into.display_name = from.display_name;
        }
    }
}
