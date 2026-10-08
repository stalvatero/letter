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

public class Mail.ContactStore : Object, PhotoSource {
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
    /* Address book photos by lowercase address, loaded once with one query
     * per book rather than one per person. */
    private HashTable<string, Gdk.Texture>? photos;
    private bool photos_loading;

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
        this.collected = new HashTable<string, Collected> (str_hash, str_equal);
        this.harvested_sent = new HashTable<string, uint8> (str_hash, str_equal);
        load_collected ();
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
        yield query_books (other_slots, sexp, needle, hits, seen, cancellable, null);

        sort_hits (hits, needle);
        return trim_hits (hits, limit);
    }

    /* The address book photo for an address. The first call starts loading
     * them all and returns null; photos_changed follows once they are in. */
    public Gdk.Texture? photo_for (string email) {
        if (this.photos == null) {
            load_photos.begin ();
            return null;
        }
        return this.photos.get (email);
    }

    private async void load_photos () {
        if (this.photos_loading || this.registry == null)
            return;
        this.photos_loading = true;
        yield ensure_books (null);
        var photos = new HashTable<string, Gdk.Texture> (str_hash, str_equal);
        for (uint i = 0; i < this.books.length; i++) {
            /* A company directory is everyone at work, not your contacts. */
            if (this.books[i].is_directory)
                continue;
            try {
                SList<E.Contact>? listed = null;
                yield this.books[i].client.get_contacts ("(exists \"photo\")", null, out listed);
                foreach (var contact in listed) {
                    var texture = contact != null ? photo_texture (contact) : null;
                    if (texture == null)
                        continue;
                    string?[] emails = {
                        contact.email_1,
                        contact.email_2,
                        contact.email_3,
                        contact.email_4,
                    };
                    foreach (var raw in emails) {
                        var email = Utils.sanitize_recipient_text (raw).down ();
                        if (email.contains ("@") && !photos.contains (email))
                            photos.set (email, texture);
                    }
                }
            } catch (Error e) {
                debug ("Address book photos: %s", e.message);
            }
            Idle.add (load_photos.callback);
            yield;
        }
        this.photos = photos;
        this.photos_loading = false;
        photos_changed ();
    }

    private static Gdk.Texture? photo_texture (E.Contact contact) {
        var photo = contact.photo;
        if (photo == null)
            return null;
        try {
            if (photo.type == E.ContactPhotoType.INLINED) {
                unowned uint8[]? data = photo.get_inlined ();
                if (data != null && data.length > 0)
                    return Gdk.Texture.from_bytes (new Bytes (data));
            } else {
                var uri = photo.get_uri ();
                if (uri != null && uri.has_prefix ("file:"))
                    return Gdk.Texture.from_file (File.new_for_uri (uri));
            }
        } catch (Error e) {
            debug ("Address book photo: %s", e.message);
        }
        return null;
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
        this.harvested_sent.set (key, 1);

        var changed = false;
        for (uint i = 0; i < messages.length; i++) {
            var message = messages[i];
            if (!message.outgoing)
                continue;
            /* Prefer raw To/Cc (with addresses). message.to/cc are display-only
             * name lists — parsing those glued every chip into one “name”. */
            if (remember_header_field (message.to_header ?? "", account, message.date, true))
                changed = true;
            if (remember_header_field (message.cc_header ?? "", account, message.date, true))
                changed = true;
        }
        if (changed)
            queue_save ();
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
