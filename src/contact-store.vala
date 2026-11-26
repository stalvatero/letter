public class Mail.ContactHit : Object {
    public string name { get; set; default = ""; }
    public string email { get; set; default = ""; }
    public bool from_book { get; set; }
    public int64 last_used { get; set; }
    public int uses { get; set; }
    public string? account_key { get; set; }

    public Recipient to_recipient () {
        return new Recipient () {
            name = this.name,
            email = this.email,
        };
    }
}

public class Mail.ContactStore : Object {
    private const uint HARVEST_USES_CAP = 50;
    private const int BOOK_QUERY_TIMEOUT_MS = 2500;

    private E.SourceRegistry? registry;
    private GenericArray<BookSlot> books = new GenericArray<BookSlot> ();
    private bool books_ready;
    private bool books_loading;
    private HashTable<string, Collected> collected;
    private HashTable<string, uint8> harvested_sent;
    private uint save_source;
    private string? prefer_key;
    private Settings settings;
    /** Lowercased emails present in EDS / Graph contacts (not Sent harvest). */
    private HashTable<string, uint8> book_emails =
        new HashTable<string, uint8> (str_hash, str_equal);
    private bool book_emails_ready;
    private bool book_emails_loading;

    private class Collected {
        public string email = "";
        public string name = "";
        public int64 last_used;
        public int uses;
        public string? account_key;
    }

    private class BookSlot {
        public E.BookClient client;
        public string source_uid;
        public GenericArray<string> identity_keys;
        public bool is_directory;
    }

    public ContactStore () {
        this.settings = new Settings (Config.APP_ID);
        this.collected = new HashTable<string, Collected> (str_hash, str_equal);
        this.harvested_sent = new HashTable<string, uint8> (str_hash, str_equal);
        load_collected ();
    }

    /** Preferences → Contacts and compose (default true). */
    public bool search_all_accounts () {
        return this.settings.get_boolean ("compose-contacts-all-accounts");
    }

    /**
     * Gathered recent addresses that are not in any address book.
     * Call refresh_book_email_index() first so Graph/EDS matches are pruned.
     */
    public GenericArray<ContactHit> list_collected () {
        var hits = new GenericArray<ContactHit> ();
        this.collected.foreach ((key, entry) => {
            if (this.book_emails_ready && this.book_emails.contains (key))
                return;
            hits.add (new ContactHit () {
                name = entry.name ?? "",
                email = entry.email ?? "",
                from_book = false,
                last_used = entry.last_used,
                uses = entry.uses,
                account_key = entry.account_key,
            });
        });
        hits.sort_with_data ((a, b) => {
            if (a.last_used != b.last_used)
                return a.last_used > b.last_used ? -1 : 1;
            return a.email.collate (b.email);
        });
        return hits;
    }

    /**
     * Rebuild the address-book email index (EDS + Graph contacts) and drop
     * collected “recent” rows that already exist in a rubrica.
     */
    public async uint refresh_book_email_index (Cancellable? cancellable = null) {
        while (this.book_emails_loading) {
            Timeout.add (50, refresh_book_email_index.callback);
            yield;
            if (cancellable != null && cancellable.is_cancelled ())
                return 0;
        }
        this.book_emails_loading = true;
        var next = new HashTable<string, uint8> (str_hash, str_equal);
        Error? err = null;
        SourceFunc callback = refresh_book_email_index.callback;
        new Thread<void*> ("letter-book-emails", () => {
            try {
                if (IdentityOAuth.microsoft_mail_uses_graph ()) {
                    IdentityCatalog catalog;
                    try {
                        catalog = IdentityCatalog.load ();
                    } catch (Error e) {
                        catalog = new IdentityCatalog ();
                    }
                    for (uint i = 0; i < catalog.accounts.length; i++) {
                        if (cancellable != null && cancellable.is_cancelled ())
                            break;
                        var acc = catalog.accounts[i];
                        if (!acc.enabled)
                            continue;
                        var kind = (acc.kind ?? "").down ();
                        if (kind != "microsoft" && kind != "ms365")
                            continue;
                        try {
                            var token = IdentityOAuth.ensure_microsoft_graph_access_sync (acc);
                            var client = new LetterGraph.Client (token);
                            client.collect_contact_emails_sync (next, cancellable);
                        } catch (Error e) {
                            warning ("Graph contacts index “%s”: %s", acc.email, e.message);
                        }
                        try {
                            var token = IdentityOAuth.ensure_microsoft_graph_access_sync (acc);
                            var client = new LetterGraph.Client (token);
                            client.collect_gal_emails_sync (next, cancellable);
                        } catch (Error e) {
                            /* Personal MSA / missing User.ReadBasic.All — contacts still apply. */
                            warning ("Graph GAL index “%s”: %s", acc.email, e.message);
                        }
                    }
                }
            } catch (Error e) {
                err = e;
            }
            Idle.add (() => {
                callback ();
                return Source.REMOVE;
            });
            return null;
        });
        yield;
        this.book_emails_loading = false;
        if (err != null)
            warning ("Address-book email index: %s", err.message);

        yield ensure_books (cancellable);
        if (cancellable == null || !cancellable.is_cancelled ()) {
            for (uint i = 0; i < this.books.length; i++) {
                if (cancellable != null && cancellable.is_cancelled ())
                    break;
                try {
                    SList<E.Contact>? listed = null;
                    yield this.books[i].client.get_contacts (
                        "(exists \"email\")",
                        cancellable,
                        out listed
                    );
                    if (listed == null)
                        continue;
                    foreach (var contact in listed) {
                        if (contact == null)
                            continue;
                        string?[] emails = {
                            contact.email_1,
                            contact.email_2,
                            contact.email_3,
                            contact.email_4,
                        };
                        for (uint e = 0; e < emails.length; e++) {
                            var key = Utils.sanitize_recipient_text (emails[e]).down ();
                            if (key.length > 0 && key.contains ("@"))
                                next.set (key, 1);
                        }
                    }
                } catch (Error e) {
                    if (e is IOError.CANCELLED)
                        break;
                    debug ("EDS contacts index: %s", e.message);
                }
            }
        }

        this.book_emails = next;
        this.book_emails_ready = true;
        return prune_collected_in_books ();
    }

    private uint prune_collected_in_books () {
        if (!this.book_emails_ready)
            return 0;
        var drop = new GenericArray<string> ();
        this.collected.foreach ((key, entry) => {
            if (this.book_emails.contains (key))
                drop.add (key);
        });
        for (uint i = 0; i < drop.length; i++)
            this.collected.remove (drop[i]);
        if (drop.length > 0)
            queue_save ();
        return drop.length;
    }

    public void bind_registry (E.SourceRegistry? registry) {
        this.registry = registry;
        this.books = new GenericArray<BookSlot> ();
        this.books_ready = false;
        this.books_loading = false;
        warm ();
    }

    public void warm () {
        if (this.registry != null)
            ensure_books.begin (null);
    }

    public GenericArray<ContactHit> search_collected (
        string raw,
        uint limit,
        Account? prefer = null
    ) {
        var needle = sanitize_query (raw);
        this.prefer_key = account_key (prefer);
        var hits = new GenericArray<ContactHit> ();
        var seen = new HashTable<string, uint8> (str_hash, str_equal);
        add_collected (hits, seen, needle, uint.MAX);
        sort_hits (hits, needle);
        return trim_hits (hits, limit);
    }

    public async GenericArray<ContactHit> search (
        string raw,
        uint limit,
        Cancellable? cancellable = null,
        bool any_field = true,
        Account? prefer = null
    ) {
        var needle = sanitize_query (raw);
        this.prefer_key = account_key (prefer);
        var hits = new GenericArray<ContactHit> ();
        var seen = new HashTable<string, uint8> (str_hash, str_equal);
        add_collected (hits, seen, needle, uint.MAX);

        if (needle.length == 0) {
            sort_hits (hits, needle);
            return trim_hits (hits, limit);
        }

        /* Graph Contacts/People/GAL first — do not wait on EDS books (SKIP_GOA
         * often has no registry; a slow EDS connect used to starve Graph). */
        yield query_graph_directory (prefer, needle, hits, seen, cancellable);
        if (cancellable != null && cancellable.is_cancelled ())
            return trim_hits (hits, limit);

        yield ensure_books (cancellable);
        if (cancellable != null && cancellable.is_cancelled ())
            return trim_hits (hits, limit);

        var sexp = book_sexp (needle, any_field);
        var prefer_slots = new GenericArray<BookSlot> ();
        var other_slots = new GenericArray<BookSlot> ();
        for (uint i = 0; i < this.books.length; i++) {
            if (book_matches_account (this.books[i], prefer))
                prefer_slots.add (this.books[i]);
            else
                other_slots.add (this.books[i]);
        }

        /* Preferred-account books first — never starve them behind another
         * account's full personal book. Cap only after both passes + sort. */
        yield query_books (prefer_slots, sexp, needle, hits, seen, cancellable, this.prefer_key);
        if (search_all_accounts ())
            yield query_books (other_slots, sexp, needle, hits, seen, cancellable, null);

        sort_hits (hits, needle);
        return trim_hits (hits, limit);
    }

    private async void query_graph_directory (
        Account? prefer,
        string needle,
        GenericArray<ContactHit> hits,
        HashTable<string, uint8> seen,
        Cancellable? cancellable
    ) {
        if (!IdentityOAuth.microsoft_mail_uses_graph ())
            return;
        if (needle.length < 2)
            return;

        GenericArray<LetterGraph.PersonHit>? people = null;
        string? score_key = account_key (prefer);
        Error? graph_error = null;
        SourceFunc callback = query_graph_directory.callback;
        var prefer_uid = prefer != null ? (prefer.source_uid ?? prefer.uid) : null;
        var all_accounts = search_all_accounts ();
        var q = needle;
        new Thread<void*> ("letter-graph-contacts", () => {
            try {
                IdentityCatalog catalog;
                try {
                    catalog = IdentityCatalog.load ();
                } catch (Error e) {
                    catalog = new IdentityCatalog ();
                }
                var id_accounts = new GenericArray<IdentityAccount> ();
                IdentityAccount? preferred = null;
                for (uint i = 0; i < catalog.accounts.length; i++) {
                    var acc = catalog.accounts[i];
                    if (!acc.enabled)
                        continue;
                    var kind = (acc.kind ?? "").down ();
                    if (kind != "microsoft" && kind != "ms365")
                        continue;
                    if (prefer_uid != null && acc.id == prefer_uid)
                        preferred = acc;
                    else if (all_accounts)
                        id_accounts.add (acc);
                }
                /* Prefer From: first; other Microsoft rows only when the
                 * “all accounts” preference is on. */
                if (preferred != null) {
                    var ordered = new GenericArray<IdentityAccount> ();
                    ordered.add (preferred);
                    for (uint i = 0; i < id_accounts.length; i++)
                        ordered.add (id_accounts[i]);
                    id_accounts = ordered;
                }
                people = new GenericArray<LetterGraph.PersonHit> ();
                if (id_accounts.length == 0) {
                    Idle.add (() => {
                        callback ();
                        return Source.REMOVE;
                    });
                    return null;
                }
                var merge_seen = new HashTable<string, uint8> (str_hash, str_equal);
                for (uint i = 0; i < id_accounts.length; i++) {
                    if (cancellable != null && cancellable.is_cancelled ())
                        break;
                    try {
                        var token = IdentityOAuth.ensure_microsoft_graph_access_sync (id_accounts[i]);
                        var client = new LetterGraph.Client (token);
                        var batch = client.search_people_for_compose_sync (q, 12, cancellable);
                        for (uint j = 0; j < batch.length; j++) {
                            var email = Utils.sanitize_recipient_text (batch[j].email).down ();
                            if (email.length == 0 || !email.contains ("@") || merge_seen.contains (email))
                                continue;
                            merge_seen.set (email, 1);
                            people.add (batch[j]);
                        }
                    } catch (Error e) {
                        warning (
                            "Graph directory search “%s”: %s",
                            id_accounts[i].email,
                            e.message
                        );
                    }
                }
            } catch (Error e) {
                graph_error = e;
            }
            Idle.add (() => {
                callback ();
                return Source.REMOVE;
            });
            return null;
        });
        yield;
        if (cancellable != null && cancellable.is_cancelled ())
            return;
        if (graph_error != null) {
            warning ("Graph directory search: %s", graph_error.message);
            return;
        }
        if (people == null)
            return;
        for (uint i = 0; i < people.length; i++) {
            var email = Utils.sanitize_recipient_text (people[i].email).down ();
            if (email.length == 0 || !email.contains ("@"))
                continue;
            var name = Utils.sanitize_recipient_text (people[i].name);
            if (seen.contains (email)) {
                /* Upgrade a recent-only row to address-book when Graph confirms. */
                for (uint h = 0; h < hits.length; h++) {
                    if (hits[h].email.down () != email)
                        continue;
                    hits[h].from_book = true;
                    if (name.length > 0
                        && (hits[h].name.length == 0
                            || hits[h].name.down () == email))
                        hits[h].name = name;
                    if (score_key != null && hits[h].account_key == null)
                        hits[h].account_key = score_key;
                    break;
                }
                continue;
            }
            seen.set (email, 1);
            hits.add (new ContactHit () {
                name = name,
                email = email,
                from_book = true,
                account_key = score_key,
                uses = 0,
                last_used = 0,
            });
        }
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
                yield this.books[i].client.get_contacts (sexp, cancellable, out listed);
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

    private async void query_books (
        GenericArray<BookSlot> slots,
        string sexp,
        string needle,
        GenericArray<ContactHit> hits,
        HashTable<string, uint8> seen,
        Cancellable? cancellable,
        string? score_account_key
    ) {
        for (uint i = 0; i < slots.length; i++) {
            if (cancellable != null && cancellable.is_cancelled ())
                break;
            var slot = slots[i];
            var book_cancel = new Cancellable ();
            ulong parent_id = 0;
            if (cancellable != null) {
                parent_id = cancellable.connect (() => {
                    book_cancel.cancel ();
                });
            }
            uint timeout = 0;
            if (slot.is_directory) {
                timeout = Timeout.add (BOOK_QUERY_TIMEOUT_MS, () => {
                    book_cancel.cancel ();
                    return Source.REMOVE;
                });
            }
            try {
                SList<E.Contact>? listed = null;
                yield slot.client.get_contacts (sexp, book_cancel, out listed);
                if (listed != null) {
                    foreach (var contact in listed) {
                        if (contact != null)
                            add_book_contact (hits, seen, contact, needle, score_account_key);
                    }
                }
            } catch (Error e) {
                if (!(e is IOError.CANCELLED))
                    debug ("Address book search: %s", e.message);
            } finally {
                if (timeout != 0)
                    Source.remove (timeout);
                if (parent_id != 0 && cancellable != null)
                    cancellable.disconnect (parent_id);
            }
            Idle.add (query_books.callback);
            yield;
        }
    }

    private void sort_hits (GenericArray<ContactHit> hits, string needle) {
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

    private static GenericArray<ContactHit> trim_hits (GenericArray<ContactHit> hits, uint limit) {
        if (hits.length <= limit)
            return hits;
        var trimmed = new GenericArray<ContactHit> ();
        for (uint i = 0; i < limit; i++)
            trimmed.add (hits[i]);
        return trimmed;
    }

    public static string? account_key (Account? account) {
        if (account == null)
            return null;
        if (account.source_uid != null && account.source_uid.length > 0)
            return account.source_uid;
        if (account.goa_id != null && account.goa_id.length > 0)
            return account.goa_id;
        return account.uid;
    }

    public void remember_recipients (
        GenericArray<Recipient> recipients,
        Account? account = null
    ) {
        remember_recipient_list (recipients, account, new DateTime.now_utc ().to_unix (), false);
    }

    /** Drop a recent/harvested address from compose suggestions (not address books). */
    public bool forget_collected (string? email) {
        var key = Utils.sanitize_recipient_text (email).down ();
        if (key.length == 0 || !this.collected.contains (key))
            return false;
        this.collected.remove (key);
        queue_save ();
        return true;
    }

    /* Seed from Sent header rows already in RAM/disk — no MIME / Graph. */
    public void harvest_sent_messages (Account account, GenericArray<Message> messages) {
        var key = account_key (account);
        if (key == null || key.length == 0)
            return;
        if (this.harvested_sent.contains (key))
            return;

        var changed = false;
        var saw_address_field = false;
        for (uint i = 0; i < messages.length; i++) {
            var message = messages[i];
            if (!message.outgoing)
                continue;
            /* Prefer raw To/Cc (with addresses). Fall back to to/cc when they
             * already carry mailboxes (Graph list headers / disk cache) —
             * display-only name lists without @ are still skipped. */
            var to_raw = harvest_address_field (message.to_header, message.to);
            var cc_raw = harvest_address_field (message.cc_header, message.cc);
            if (to_raw.length > 0 || cc_raw.length > 0)
                saw_address_field = true;
            if (remember_header_field (to_raw, account, message.date, true))
                changed = true;
            if (remember_header_field (cc_raw, account, message.date, true))
                changed = true;
        }
        /* Seal the one-shot only after a useful scan. If Sent tip/disk lacked
         * address fields (old Graph rows without to_header), retry later. */
        if (changed) {
            this.harvested_sent.set (key, 1);
            queue_save ();
        } else if (saw_address_field) {
            this.harvested_sent.set (key, 1);
        }
    }

    private static string harvest_address_field (string? preferred, string? fallback) {
        if (preferred != null && preferred.contains ("@"))
            return preferred;
        if (fallback != null && fallback.contains ("@"))
            return fallback;
        return "";
    }

    public void remember_outgoing_headers (
        Account? account,
        string? to_raw,
        string? cc_raw,
        int64 date
    ) {
        var when = date > 0 ? date : new DateTime.now_utc ().to_unix ();
        var changed = false;
        if (remember_header_field (to_raw, account, when, true))
            changed = true;
        if (remember_header_field (cc_raw, account, when, true))
            changed = true;
        if (changed)
            queue_save ();
    }

    private bool remember_header_field (
        string? raw,
        Account? account,
        int64 date,
        bool harvest
    ) {
        if (raw == null || raw.strip ().length == 0)
            return false;
        /* Display-only lists (no mailbox) must never be harvested. */
        if (!raw.contains ("@"))
            return false;
        var recipients = Utils.parse_recipient_list (raw);
        return remember_recipient_list (recipients, account, date, harvest);
    }

    private bool remember_recipient_list (
        GenericArray<Recipient> recipients,
        Account? account,
        int64 date,
        bool harvest
    ) {
        var key = account_key (account);
        var changed = false;
        for (uint i = 0; i < recipients.length; i++) {
            var email = Utils.sanitize_recipient_text (recipients[i].email).down ();
            if (!usable_collected_email (email))
                continue;
            var name = sanitize_collected_name (
                Utils.sanitize_recipient_text (recipients[i].name),
                email
            );
            var entry = this.collected.get (email);
            if (entry == null) {
                entry = new Collected ();
                entry.email = email;
                entry.uses = 0;
                this.collected.set (email, entry);
            }
            if (name.length > 0 && name_fits_email (name, email)) {
                if (entry.name.length == 0 || !name_fits_email (entry.name, email))
                    entry.name = name;
                else if (entry.name != name && name_fits_email (name, email))
                    entry.name = name;
            }
            if (date > entry.last_used)
                entry.last_used = date;
            if (harvest) {
                if (entry.uses < (int) HARVEST_USES_CAP)
                    entry.uses++;
            } else {
                entry.uses++;
                entry.last_used = date;
            }
            if (key != null && key.length > 0)
                entry.account_key = key;
            changed = true;
        }
        if (changed && !harvest)
            queue_save ();
        return changed;
    }

    private static bool usable_collected_email (string email) {
        if (email.length == 0 || !email.contains ("@"))
            return false;
        if (email.contains (" ") || email.contains (",") || email.contains (";"))
            return false;
        var at = email.index_of_char ('@');
        if (at <= 0 || at >= email.length - 1)
            return false;
        if (email.index_of_char ('@', at + 1) >= 0)
            return false;
        return email.substring (at + 1).contains (".");
    }

    /* "Last, First" is fine; "Ada Ada, Bob Bob, …" is a glued To: display list. */
    private static bool looks_like_merged_people_name (string name) {
        if (name.contains ("@"))
            return true;
        var parts = name.split (",");
        if (parts.length < 2)
            return false;
        int person_like = 0;
        foreach (var part in parts) {
            var token = part.strip ();
            if (token.length == 0)
                continue;
            if (token.contains (" "))
                person_like++;
        }
        return person_like >= 2;
    }

    /* Drop names that clearly do not belong to this mailbox (harvest glued
     * the wrong display name onto someone else's address). */
    private static bool name_fits_email (string name, string email) {
        if (name.length == 0)
            return true;
        if (looks_like_merged_people_name (name))
            return false;
        var at = email.index_of_char ('@');
        if (at <= 0)
            return false;
        var local = email.substring (0, at).down ();
        var local_spaced = local
            .replace (".", " ")
            .replace ("_", " ")
            .replace ("-", " ");
        var local_compact = local
            .replace (".", "")
            .replace ("_", "")
            .replace ("-", "");
        var name_d = name.down ();
        foreach (var raw_token in name_d.split (" ")) {
            var token = raw_token.strip ();
            if (token.length < 3)
                continue;
            if (local_spaced.contains (token) || local_compact.contains (token))
                return true;
        }
        foreach (var raw_token in local_spaced.split (" ")) {
            var token = raw_token.strip ();
            if (token.length < 3)
                continue;
            if (name_d.contains (token))
                return true;
        }
        return false;
    }

    private static string sanitize_collected_name (string name, string email = "") {
        if (name.length == 0 || looks_like_merged_people_name (name))
            return "";
        if (email.length > 0 && !name_fits_email (name, email))
            return "";
        return name;
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
                if (!source_for_autocomplete (source))
                    continue;
                try {
                    var client = yield E.BookClient.connect (source, 3, cancellable);
                    var slot = new BookSlot ();
                    slot.client = client;
                    slot.source_uid = source.get_uid () ?? "";
                    slot.identity_keys = source_identity_keys (source);
                    slot.is_directory = source_looks_like_directory (source);
                    this.books.add (slot);
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

    /* Prefer EDS Autocomplete IncludeMe; without the extension keep personal
     * books and skip classic remote-directory names (pre-IncludeMe sources). */
    private static bool source_for_autocomplete (E.Source source) {
        if (source.has_extension (E.SOURCE_EXTENSION_AUTOCOMPLETE)) {
            var auto = (E.SourceAutocomplete) source.get_extension (E.SOURCE_EXTENSION_AUTOCOMPLETE);
            return auto.get_include_me ();
        }
        return !source_looks_like_directory (source);
    }

    private static bool source_looks_like_directory (E.Source source) {
        var name = (source.dup_display_name () ?? "").down ();
        var uid = source.get_uid ().down ();
        return name.contains ("organizational")
            || name.contains ("global address")
            || name.contains ("gal")
            || uid.contains ("organizational")
            || uid.contains ("gal");
    }

    private GenericArray<string> source_identity_keys (E.Source source) {
        var keys = new GenericArray<string> ();
        append_source_keys (keys, source);
        var parent_uid = source.get_parent ();
        var guard = 0;
        while (parent_uid != null && parent_uid.length > 0 && guard++ < 8) {
            if (this.registry == null)
                break;
            var parent = this.registry.ref_source (parent_uid);
            if (parent == null)
                break;
            append_source_keys (keys, parent);
            parent_uid = parent.get_parent ();
        }
        return keys;
    }

    private static void append_source_keys (GenericArray<string> keys, E.Source source) {
        var uid = source.get_uid ();
        if (uid != null && uid.length > 0)
            keys.add (uid);
        if (source.has_extension (E.SOURCE_EXTENSION_GOA)) {
            var goa = (E.SourceGoa) source.get_extension (E.SOURCE_EXTENSION_GOA);
            var id = goa.dup_account_id ();
            if (id != null && id.length > 0)
                keys.add (id);
        }
        if (source.has_extension (E.SOURCE_EXTENSION_COLLECTION)) {
            var collection = (E.SourceCollection) source.get_extension (E.SOURCE_EXTENSION_COLLECTION);
            var identity = collection.dup_identity ();
            if (identity != null && identity.length > 0)
                keys.add (identity);
        }
    }

    private static bool book_matches_account (BookSlot slot, Account? account) {
        if (account == null)
            return false;
        string?[] account_ids = {
            account.source_uid,
            account.goa_id,
            account.uid,
        };
        for (uint i = 0; i < slot.identity_keys.length; i++) {
            var key = slot.identity_keys[i];
            for (uint j = 0; j < account_ids.length; j++) {
                if (account_ids[j] != null && account_ids[j].length > 0 && account_ids[j] == key)
                    return true;
            }
        }
        return false;
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
            if (!collected_allowed_for_prefer (entry))
                return;
            if (this.book_emails_ready && this.book_emails.contains (key))
                return;
            /* History is keyed by mailbox: match the address (and a name only
             * when it actually belongs to that address). Never surface
             * “Lupo Giovanni” glued onto advertising@…. */
            if (needle.length > 0 && !matches_collected (entry.name, entry.email, needle))
                return;
            seen.set (key, 1);
            hits.add (new ContactHit () {
                name = entry.name ?? "",
                email = entry.email ?? "",
                from_book = false,
                last_used = entry.last_used,
                uses = entry.uses,
                account_key = entry.account_key,
            });
        });
    }

    private bool collected_allowed_for_prefer (Collected entry) {
        if (search_all_accounts ())
            return true;
        if (this.prefer_key == null || this.prefer_key.length == 0)
            return true;
        var key = entry.account_key ?? "";
        return key.length > 0 && key == this.prefer_key;
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
        string? score_account_key
    ) {
        var name = display_name (contact);
        string?[] emails = {
            contact.email_1,
            contact.email_2,
            contact.email_3,
            contact.email_4,
        };
        for (uint i = 0; i < emails.length; i++) {
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
                account_key = score_account_key,
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
        if (needle.length == 0)
            return true;
        var hay_name = name ?? "";
        var hay_email = email ?? "";
        return hay_name.down ().contains (needle) || hay_email.contains (needle);
    }

    private static bool matches_collected (string? name, string? email, string needle) {
        if (needle.length == 0)
            return true;
        var hay_email = (email ?? "").down ();
        if (hay_email.contains (needle))
            return true;
        var hay_name = name ?? "";
        if (hay_name.down ().contains (needle) && name_fits_email (hay_name, hay_email))
            return true;
        return false;
    }

    private int compare_hits (ContactHit a, ContactHit b, string needle) {
        int sa = score (a, needle);
        int sb = score (b, needle);
        if (sa != sb)
            return sb - sa;
        if (a.last_used != b.last_used)
            return a.last_used > b.last_used ? -1 : 1;
        return a.name.collate (b.name);
    }

    private int score (ContactHit hit, string needle) {
        var points = 0;
        if (!hit.from_book) {
            /* Frequency / recency must beat a cold address-book near-match. */
            points += int.min (hit.uses * 12, 180);
            points += recency_points (hit.last_used);
            if (same_prefer_account (hit.account_key))
                points += 80;
        } else {
            points += 5;
            if (same_prefer_account (hit.account_key))
                points += 40;
        }

        if (needle.length == 0)
            return points;

        var name = hit.name.down ();
        var email = hit.email.down ();
        var at = email.index_of_char ('@');
        var local = at > 0 ? email.substring (0, at) : email;
        /* Mailbox match always outranks a display-name hit — “lupo” must
         * prefer g.lupo@… over an unrelated address that inherited that name. */
        if (local.has_prefix (needle) || email.has_prefix (needle))
            return 500 + points;
        if (local.contains (needle) || email.contains (needle))
            return 400 + points;
        if (hit.from_book && name.has_prefix (needle))
            return 200 + points;
        if (hit.from_book && name.contains (needle))
            return 120 + points;
        if (name.has_prefix (needle))
            return 80 + points;
        if (name.contains (needle))
            return 40 + points;
        return points;
    }

    private bool same_prefer_account (string? hit_key) {
        if (this.prefer_key == null || this.prefer_key.length == 0)
            return false;
        if (hit_key == null || hit_key.length == 0)
            return false;
        return hit_key == this.prefer_key;
    }

    private static int recency_points (int64 last_used) {
        if (last_used <= 0)
            return 0;
        var now = new DateTime.now_utc ().to_unix ();
        var age = now - last_used;
        if (age < 0)
            age = 0;
        if (age < 7 * 24 * 3600)
            return 100;
        if (age < 30 * 24 * 3600)
            return 70;
        if (age < 180 * 24 * 3600)
            return 40;
        if (age < 365 * 24 * 3600)
            return 20;
        return 5;
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

        var cleaned = false;
        foreach (var line in contents.split ("\n")) {
            if (line.length == 0 || line.has_prefix ("#"))
                continue;
            var parts = line.split ("\t", 5);
            if (parts.length < 1 || parts[0].length == 0)
                continue;
            var email = parts[0].down ();
            if (!usable_collected_email (email)) {
                cleaned = true;
                continue;
            }
            var entry = new Collected ();
            entry.email = email;
            var name = parts.length > 1 ? unescape_field (parts[1]) : "";
            entry.name = sanitize_collected_name (name, email);
            if (name.length > 0 && entry.name.length == 0)
                cleaned = true;
            entry.last_used = parts.length > 2 ? int64.parse (parts[2]) : 0;
            entry.uses = parts.length > 3 ? int.parse (parts[3]) : 1;
            if (parts.length > 4 && parts[4].length > 0)
                entry.account_key = parts[4];
            this.collected.set (entry.email, entry);
        }
        if (cleaned)
            queue_save ();
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
            builder.append_c ('\t');
            builder.append (entry.account_key ?? "");
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
