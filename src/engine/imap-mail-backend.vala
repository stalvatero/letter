/**
 * Letter IMAP MailBackend — Phase 2 slice 1 (no Camel).
 *
 * Real: list_folders, list_messages (online headers), load_message / body peek.
 * Everything else: safe no-op or NOT_SUPPORTED so the shell does not crash.
 */
public class Mail.ImapMailBackend : Object, MailBackend {
    /* Newest N headers for a brief tip. Until-done walks the rest in chunks. */
    public const uint LIST_HEADER_CAP = 2500;
    public const uint LIST_HEADER_CHUNK = 500;
    /* Per align call (until-done): 4×500 so Window can paint/save between slices. */
    public const uint LIST_HEADER_UNTIL_DONE_SLICES = 4;

    private bool _header_sync_busy;
    private bool _last_list_refresh_incomplete;
    private bool _last_list_refresh_failed;
    private bool _last_list_refresh_completed;
    private bool _last_list_refresh_authoritative;

    public bool header_sync_busy {
        get { return this._header_sync_busy; }
    }
    public bool last_list_refresh_incomplete {
        get { return this._last_list_refresh_incomplete; }
    }
    public bool last_list_refresh_failed {
        get { return this._last_list_refresh_failed; }
    }
    public bool last_list_refresh_completed {
        get { return this._last_list_refresh_completed; }
    }
    /* Own-engine lists have no Camel summary trap — finished walk is trusted. */
    public bool last_list_refresh_authoritative {
        get { return this._last_list_refresh_authoritative; }
    }

    /* account_uid\nfolder_full_name\nmsg_uid → MessageContent */
    private HashTable<string, MessageContent> body_ram;
    /* account_uid\nfolder_full_name → last STATUS/SELECT counts */
    private HashTable<string, int> folder_exists;
    private HashTable<string, int> folder_unseen;
    /* Soft-mutation registry (cache-first): flags + moves on disk. */
    private GenericArray<FlagJob> flag_queue;
    private GenericArray<TransferJob> transfer_queue;
    private HashTable<string, uint8> retired_uids;
    private HashTable<string, uint8> folders_pending_flags;
    private uint registry_save_source;
    private bool registry_loaded;
    private bool flush_running;
    /* local-sent-* / local-draft-* bodies until server UID replaces them. */
    private HashTable<string, MessageContent> local_outgoing_bodies;
    /* Last LIST tree per account (no STATUS) — resolve Drafts/Sent without a full walk. */
    private HashTable<string, GenericArray<Folder>> folder_list_cache;
    /* local-draft-* → server UID after APPENDUID (so re-save purges the server copy). */
    private HashTable<string, string> draft_local_to_server;
    private HashTable<string, Cancellable> draft_append_cancels;
    private IdentityCatalog catalog = new IdentityCatalog ();
    /* Folded plain-text body cache for search (same files as Camel path). */
    private BodyTextIndex body_text_index = new BodyTextIndex ();
    /* Newest-first body prefetch resume (same file as Camel MailSession). */
    private HashTable<string, int> prefetch_cursor;
    private bool prefetch_cursors_loaded = false;
    private uint prefetch_cursor_save_source = 0;
    /* Until-done header walk: next to_seq (descending) per folder. */
    private HashTable<string, uint> header_walk_to_seq;
    private bool header_walk_loaded = false;
    private uint header_walk_save_source = 0;
    /* Serialize connect / catalog / libsecret / OAuth (not thread-safe). */
    private Mutex imap_io_lock;
    /* idle_watches + pending_headers + EXISTS map touches from worker threads. */
    private Mutex idle_state_lock;
    /* Long-lived IDLE connections (one per watched mailbox). */
    private HashTable<string, IdleWatch> idle_watches;
    /* Inbox + open folder (prefer dropping non-Inbox when at the cap). */
    public const uint IDLE_MAX_WATCHES = 2;
    public const uint IDLE_RENEW_SECONDS = 20 * 60;

    private class PendingFlagUpdate {
        public bool seen;
        public bool flagged;
    }

    private class IdleWatch {
        public Account account;
        public string folder_full_name;
        public string folder_name;
        public string folder_key;
        public string watch_key;
        public bool is_inbox;
        public Cancellable cancellable;
        public uint last_exists;
        /* Dense seq→UID: index 0 = sequence 1. Rebuild on SELECT / reconnect. */
        public GenericArray<string> seq_uids;
        public GenericArray<Message> pending_headers;
        public HashTable<string, PendingFlagUpdate> pending_flags;
        public GenericArray<string> pending_removed;
        public bool thread_running;
    }

    private class FlagJob {
        public Account account;
        public Folder folder;
        public GenericArray<string> uids;
        public string flag_atom; /* \\Seen / \\Flagged */
        public bool add;
    }

    private class TransferJob {
        public Account account;
        public Folder from;
        public Folder destination;
        public GenericArray<string> uids;
        public bool delete_original;
    }

    public ImapMailBackend () {
        this.body_ram = new HashTable<string, MessageContent> (str_hash, str_equal);
        this.folder_exists = new HashTable<string, int> (str_hash, str_equal);
        this.folder_unseen = new HashTable<string, int> (str_hash, str_equal);
        this.flag_queue = new GenericArray<FlagJob> ();
        this.transfer_queue = new GenericArray<TransferJob> ();
        this.retired_uids = new HashTable<string, uint8> (str_hash, str_equal);
        this.folders_pending_flags = new HashTable<string, uint8> (str_hash, str_equal);
        this.local_outgoing_bodies = new HashTable<string, MessageContent> (str_hash, str_equal);
        this.folder_list_cache = new HashTable<string, GenericArray<Folder>> (str_hash, str_equal);
        this.draft_local_to_server = new HashTable<string, string> (str_hash, str_equal);
        this.draft_append_cancels = new HashTable<string, Cancellable> (str_hash, str_equal);
        this.idle_watches = new HashTable<string, IdleWatch> (str_hash, str_equal);
        this.prefetch_cursor = new HashTable<string, int> (str_hash, str_equal);
        this.header_walk_to_seq = new HashTable<string, uint> (str_hash, str_equal);
        this.imap_io_lock = Mutex ();
        this.idle_state_lock = Mutex ();
        try {
            this.catalog = IdentityCatalog.load ();
        } catch (Error e) {
            warning ("ImapMailBackend: identity catalog: %s", e.message);
            this.catalog = new IdentityCatalog ();
        }
    }

    public async GenericArray<Folder> list_folders (
        Account account,
        Cancellable? cancellable = null,
        bool refresh = true
    ) throws Error {
        GenericArray<Folder>? result = null;
        Error? error = null;
        SourceFunc callback = list_folders.callback;
        new Thread<void*> ("letter-imap-folders", () => {
            try {
                result = list_folders_sync (account, cancellable);
            } catch (Error e) {
                error = e;
            }
            Idle.add (() => {
                callback ();
                return Source.REMOVE;
            });
            return null;
        });
        yield;
        if (error != null)
            throw error;
        return result ?? new GenericArray<Folder> ();
    }

    private GenericArray<Folder> list_folders_sync (
        Account account,
        Cancellable? cancellable
    ) throws Error {
        var client = open_client (account, cancellable);
        try {
            var names = client.list_mailboxes (cancellable);
            /* Same nest / Gmail lift / sort_rank / flatten as Camel list_folders. */
            var folders = MailSession.folders_from_imap_paths (names);
            for (uint i = 0; i < folders.length; i++) {
                var folder = folders[i];
                /* Display leaf in Unicode; full_name stays wire Modified UTF-7 for SELECT. */
                folder.name = LetterImap.Client.decode_mailbox_name (folder.name);
                MailSession.apply_folder_display_name (folder);

                if (folder.is_gmail_namespace || folder.is_virtual_view)
                    continue;
                try {
                    var st = client.status_mailbox (folder.full_name, cancellable);
                    folder.server_total = (int) st.messages;
                    folder.server_unread = (int) st.unseen;
                    folder.total = folder.server_total;
                    folder.unread = folder.server_unread;
                    var key = folder_key (account, folder);
                    this.folder_exists.set (key, folder.server_total);
                    this.folder_unseen.set (key, folder.server_unread);
                } catch (Error e) {
                    debug ("STATUS %s: %s", folder.full_name, e.message);
                }
            }
            this.folder_list_cache.set (account.uid, folders);
            return folders;
        } finally {
            client.logout (null);
        }
    }

    public async GenericArray<Message> list_messages (
        Account account,
        Folder folder,
        bool refresh,
        Cancellable? cancellable = null,
        bool watch = false,
        GenericArray<Message>? previous = null,
        bool high = false,
        uint refresh_timeout_seconds = 0
    ) throws Error {
        /* Cache-first (refresh=false): RAM/disk only — never open IMAP.
         * Window primes from letter-headers-v1; empty means “not indexed yet”,
         * not “fetch the whole Trash in parallel with folder sync”. */
        if (!refresh) {
            this._last_list_refresh_completed = true;
            this._last_list_refresh_failed = false;
            this._last_list_refresh_incomplete = false;
            this._last_list_refresh_authoritative = false;
            return previous ?? new GenericArray<Message> ();
        }

        this._header_sync_busy = true;
        this._last_list_refresh_incomplete = false;
        this._last_list_refresh_failed = false;
        this._last_list_refresh_completed = false;
        this._last_list_refresh_authoritative = false;
        try {
            GenericArray<Message>? result = null;
            Error? error = null;
            var incomplete = false;
            SourceFunc callback = list_messages.callback;
            new Thread<void*> ("letter-imap-list", () => {
                try {
                    result = list_messages_sync (
                        account,
                        folder,
                        cancellable,
                        refresh_timeout_seconds,
                        out incomplete
                    );
                } catch (Error e) {
                    error = e;
                }
                Idle.add (() => {
                    callback ();
                    return Source.REMOVE;
                });
                return null;
            });
            yield;
            if (error != null) {
                this._last_list_refresh_failed = true;
                throw error;
            }
            this._last_list_refresh_incomplete = incomplete;
            this._last_list_refresh_completed = !incomplete;
            this._last_list_refresh_authoritative = !incomplete;
            var listed = result ?? new GenericArray<Message> ();
            sort_by_date_desc (listed);
            /* Tip (incomplete): merge into prior Letter headers so a 2500-cap
             * FETCH never drops older UIDs already on disk/RAM. */
            if (incomplete && previous != null && previous.length > 0)
                listed = merge_tip_into_previous (previous, listed);
            /* Keep local-sent-* until the server UID lands (subject/date match). */
            listed = retain_local_placeholders (listed, previous);
            /* Finished walk is source of truth — drop orphan .eml left after
             * Empty Trash / moves / other-client deletes (header index already
             * matches the server; bodies were never pruned). */
            if (!incomplete)
                prune_orphan_bodies (account, folder, listed);
            return listed;
        } finally {
            this._header_sync_busy = false;
        }
    }

    private GenericArray<Message> list_messages_sync (
        Account account,
        Folder folder,
        Cancellable? cancellable,
        uint refresh_timeout_seconds,
        out bool incomplete
    ) throws Error {
        incomplete = false;
        var until_done = refresh_timeout_seconds == MailSession.REFRESH_INFO_FORCE_UNTIL_DONE;
        var client = open_client (account, cancellable);
        try {
            var exists = client.select (folder.full_name, cancellable);
            /* EXISTS updates the STATUS total floor; UNSEEN stays from STATUS. */
            this.folder_exists.set (folder_key (account, folder), (int) exists);
            var listed = new GenericArray<Message> ();
            if (exists == 0)
                return listed;

            var walk_key = prefetch_cursor_key (account, folder);
            ensure_header_walk_loaded ();

            if (!until_done) {
                /* Brief tip: newest N, chunked (Outlook chokes on a single
                 * 2500-UID FETCH with header literals). Incomplete → Window
                 * escalates to until-done on folder open / Update Folder. */
                uint to_seq = exists;
                uint tip_from = exists > LIST_HEADER_CAP
                    ? exists - LIST_HEADER_CAP + 1
                    : 1;
                while (to_seq >= tip_from) {
                    if (cancellable != null && cancellable.is_cancelled ()) {
                        incomplete = true;
                        break;
                    }
                    uint from_seq = to_seq > LIST_HEADER_CHUNK
                        ? to_seq - LIST_HEADER_CHUNK + 1
                        : tip_from;
                    if (from_seq < tip_from)
                        from_seq = tip_from;
                    append_header_range (client, folder, from_seq, to_seq, listed, cancellable);
                    if (from_seq <= tip_from)
                        break;
                    to_seq = from_seq - 1;
                }
                incomplete = tip_from > 1 || listed.length < exists;
                /* Seed until-done so the next pass walks older than the tip. */
                if (tip_from > 1)
                    set_header_walk_to_seq (walk_key, tip_from - 1);
                else
                    clear_header_walk_to_seq (walk_key);
                return listed;
            }

            /* Full walk in slices (All Mail / Important). Window re-calls
             * until-done while incomplete so each slice can hit disk/UI. */
            uint to_seq = exists;
            if (this.header_walk_to_seq.contains (walk_key)) {
                var resume = this.header_walk_to_seq.get (walk_key);
                if (resume >= 1 && resume <= exists)
                    to_seq = resume;
            }
            uint slices = 0;
            while (to_seq >= 1 && slices < LIST_HEADER_UNTIL_DONE_SLICES) {
                if (cancellable != null && cancellable.is_cancelled ()) {
                    incomplete = true;
                    set_header_walk_to_seq (walk_key, to_seq);
                    break;
                }
                uint from_seq = to_seq > LIST_HEADER_CHUNK
                    ? to_seq - LIST_HEADER_CHUNK + 1
                    : 1;
                append_header_range (client, folder, from_seq, to_seq, listed, cancellable);
                slices++;
                if (from_seq <= 1) {
                    to_seq = 0;
                    break;
                }
                to_seq = from_seq - 1;
            }
            if (!incomplete) {
                if (to_seq >= 1) {
                    incomplete = true;
                    set_header_walk_to_seq (walk_key, to_seq);
                } else {
                    clear_header_walk_to_seq (walk_key);
                }
            }
            if (slices > 0 || incomplete) {
                Utils.sync_log (
                    "imap headers until-done “%s” +%u this slice (exists %u, next_to=%u%s)".printf (
                        folder.name,
                        listed.length,
                        exists,
                        to_seq,
                        incomplete ? ", incomplete" : ""
                    )
                );
            }
            return listed;
        } finally {
            client.logout (null);
        }
    }

    private void set_header_walk_to_seq (string walk_key, uint to_seq) {
        this.header_walk_to_seq.set (walk_key, to_seq);
        schedule_header_walk_save ();
    }

    private void clear_header_walk_to_seq (string walk_key) {
        if (this.header_walk_to_seq.remove (walk_key))
            schedule_header_walk_save ();
    }

    private static string header_walk_cache_dir () {
        return Path.build_filename (Environment.get_user_cache_dir (), "letter", "header-walk");
    }

    private static string header_walk_cache_file () {
        return Path.build_filename (header_walk_cache_dir (), "cursors");
    }

    private void ensure_header_walk_loaded () {
        if (this.header_walk_loaded)
            return;
        this.header_walk_loaded = true;
        var path = header_walk_cache_file ();
        if (!FileUtils.test (path, FileTest.IS_REGULAR))
            return;
        try {
            var key = new KeyFile ();
            key.load_from_file (path, KeyFileFlags.NONE);
            if (!key.has_group ("walk"))
                return;
            foreach (var entry in key.get_keys ("walk"))
                this.header_walk_to_seq.set (entry, (uint) key.get_uint64 ("walk", entry));
        } catch (Error e) {
            debug ("ImapMailBackend: header walk cursors: %s", e.message);
        }
    }

    private void schedule_header_walk_save () {
        if (this.header_walk_save_source != 0)
            return;
        this.header_walk_save_source = Timeout.add (1500, () => {
            this.header_walk_save_source = 0;
            save_header_walk_cursors ();
            return Source.REMOVE;
        });
    }

    private void save_header_walk_cursors () {
        try {
            File.new_for_path (header_walk_cache_dir ()).make_directory_with_parents ();
        } catch (Error e) {
            if (!(e is IOError.EXISTS)) {
                debug ("ImapMailBackend: header walk dir: %s", e.message);
                return;
            }
        }
        var key = new KeyFile ();
        this.header_walk_to_seq.foreach ((k, value) => {
            key.set_uint64 ("walk", k, value);
        });
        try {
            key.save_to_file (header_walk_cache_file ());
        } catch (Error e) {
            debug ("ImapMailBackend: header walk write: %s", e.message);
        }
    }

    private static void append_header_range (
        LetterImap.Client client,
        Folder folder,
        uint from_seq,
        uint to_seq,
        GenericArray<Message> listed,
        Cancellable? cancellable
    ) throws Error {
        var headers = client.fetch_headers (from_seq, to_seq, cancellable);
        /* FETCH order is usually ascending seq; keep newest-first in listed. */
        for (int i = (int) headers.length - 1; i >= 0; i--) {
            var h = headers[(uint) i];
            var uid = h.uid;
            if (uid == null || uid.length == 0)
                uid = "%u".printf (h.seq);
            var from_raw = decode_rfc2047 (h.from) ?? _("Unknown sender");
            var msgid = decode_rfc2047 (h.message_id);
            var in_reply = decode_rfc2047 (h.in_reply_to);
            var references = decode_rfc2047 (h.references);
            var date = parse_mail_date (h.date);
            if (date <= 0)
                date = parse_imap_internaldate (h.internal_date);
            listed.add (new Message () {
                uid = uid,
                subject = decode_rfc2047 (h.subject) ?? _("(No subject)"),
                from = format_from_display (from_raw),
                to = decode_rfc2047 (h.to) ?? "",
                date = date,
                seen = h.seen,
                flagged = h.flagged,
                has_attachment = h.has_attachment,
                folder_name = folder.name,
                folder_full_name = folder.full_name,
                list_address = format_from_display (from_raw),
                msgid_hash = MailSession.hash_message_id_raw (msgid),
                msgid_refs = MailSession.msgid_refs_from_raw_headers (in_reply, references),
            });
        }
    }

    public async void follow_folder (Account account, Folder folder) throws Error {
        if (folder.is_virtual_view || folder.is_gmail_namespace)
            return;
        /* Cap at Inbox + open folder. Window only auto-watches Inbox for
         * letter-imap; open_folder calls follow_folder for the selected one. */

        var key = watch_key (account, folder);
        string? drop = null;
        IdleWatch? watch = null;
        string? account_key = null;
        string? folder_full = null;
        string? log_name = null;

        this.idle_state_lock.lock ();
        try {
            var existing = this.idle_watches.get (key);
            if (existing != null && existing.thread_running)
                return;

            if (this.idle_watches.size () >= IDLE_MAX_WATCHES && existing == null) {
                string? non_inbox = null;
                string? any = null;
                this.idle_watches.foreach ((k, w) => {
                    if (any == null)
                        any = k;
                    if (!w.is_inbox && non_inbox == null)
                        non_inbox = k;
                });
                drop = non_inbox ?? any;
            }
        } finally {
            this.idle_state_lock.unlock ();
        }

        if (drop != null)
            stop_idle_watch (drop);

        this.idle_state_lock.lock ();
        try {
            var existing = this.idle_watches.get (key);
            if (existing != null && existing.thread_running)
                return;

            watch = existing ?? new IdleWatch ();
            watch.account = account;
            watch.folder_full_name = folder.full_name;
            watch.folder_name = folder.name;
            watch.folder_key = folder_key (account, folder);
            watch.watch_key = key;
            watch.is_inbox = folder.kind == FolderKind.INBOX;
            watch.cancellable = new Cancellable ();
            watch.seq_uids = new GenericArray<string> ();
            watch.pending_headers = new GenericArray<Message> ();
            watch.pending_flags = new HashTable<string, PendingFlagUpdate> (str_hash, str_equal);
            watch.pending_removed = new GenericArray<string> ();
            watch.thread_running = true;
            if (this.folder_exists.contains (watch.folder_key))
                watch.last_exists = (uint) this.folder_exists.get (watch.folder_key);
            else
                watch.last_exists = 0;
            this.idle_watches.set (key, watch);
            account_key = account.source_uid ?? account.uid;
            folder_full = folder.full_name;
            log_name = folder.name;
        } finally {
            this.idle_state_lock.unlock ();
        }

        if (watch == null || account_key == null || folder_full == null)
            return;

        var watch_ref = watch;
        var acc_key = account_key;
        var fold_full = folder_full;
        new Thread<void*> ("letter-imap-idle", () => {
            idle_loop (watch_ref, acc_key, fold_full);
            return null;
        });
        Utils.sync_log ("IDLE watch “%s”".printf (log_name ?? folder.name));
    }

    public async GenericArray<Message> search_folder_local (
        Account account,
        Folder folder,
        SearchQuery query,
        bool include_body = true,
        uint limit = 400
    ) throws Error {
        var messages = new GenericArray<Message> ();
        if (query.is_empty || limit == 0 || folder.is_virtual_view)
            return messages;
        /* Window already scanned Letter headers; body pass needs TEXT clauses. */
        if (!include_body || !query_has_text_clause (query))
            return messages;

        var uids = search_body_index (account, folder, query, limit);
        Idle.add (search_folder_local.callback);
        yield;

        for (uint i = 0; i < uids.length && messages.length < limit; i++) {
            messages.add (new Message () {
                uid = uids[i],
                subject = "",
                from = "",
                to = "",
                folder_name = folder.name,
                folder_full_name = folder.full_name,
            });
            if (i % 64 == 63) {
                Idle.add (search_folder_local.callback);
                yield;
            }
        }
        return messages;
    }

    public async uint index_more_cached_bodies (
        Account account,
        Folder folder,
        uint max_new = 500,
        Cancellable? cancellable = null
    ) throws Error {
        if (max_new == 0 || folder.is_virtual_view)
            return 0;

        var account_uid = account.source_uid ?? account.uid;
        var dir = body_dir (account, folder);
        if (!dir.query_exists (cancellable))
            return 0;

        var pending = new GenericArray<string> ();
        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME,
                FileQueryInfoFlags.NONE,
                cancellable
            );
            FileInfo? info;
            while ((info = enumerator.next_file (cancellable)) != null) {
                var name = info.get_name ();
                if (name == null || !name.has_suffix (".eml"))
                    continue;
                var uid = name.substring (0, name.length - 4);
                if (uid.length == 0)
                    continue;
                if (this.body_text_index.has (account_uid, folder.full_name, uid))
                    continue;
                pending.add (uid);
                if (pending.length >= max_new)
                    break;
            }
        } catch (Error e) {
            if (e is IOError.CANCELLED)
                throw e;
            warning ("ImapMailBackend index list “%s”: %s", folder.name, e.message);
            return 0;
        }
        if (pending.length == 0)
            return 0;

        /* MIME parse off the main thread — warm Importanti froze GTK when
         * this walked on Idle yields alone. */
        var plains = new GenericArray<string> ();
        var uids_ok = new GenericArray<string> ();
        Error? index_error = null;
        SourceFunc callback = index_more_cached_bodies.callback;
        var acc = account;
        var fold = folder;
        new Thread<void*> ("letter-imap-body-index", () => {
            try {
                for (uint i = 0; i < pending.length; i++) {
                    if (cancellable != null && cancellable.is_cancelled ())
                        break;
                    var uid = pending[i];
                    try {
                        var file = body_file (acc, fold, uid);
                        if (!file.query_exists (null))
                            continue;
                        uint8[] data;
                        string etag;
                        file.load_contents (null, out data, out etag);
                        var content = content_from_rfc822 (uid, (string) data);
                        var plain = searchable_plain (content);
                        if (plain == null || plain.strip ().length == 0)
                            plain = "";
                        uids_ok.add (uid);
                        plains.add (plain);
                    } catch (Error e) {
                        if (e is IOError.CANCELLED)
                            throw e;
                        debug ("ImapMailBackend index file %s: %s", uid, e.message);
                    }
                }
            } catch (Error e) {
                index_error = e;
            }
            Idle.add (() => {
                callback ();
                return Source.REMOVE;
            });
            return null;
        });
        yield;
        if (index_error != null)
            throw index_error;

        uint added = 0;
        for (uint i = 0; i < uids_ok.length; i++) {
            this.body_text_index.add (account_uid, folder.full_name, uids_ok[i], plains[i]);
            added++;
            if (i % 32 == 31) {
                Idle.add (index_more_cached_bodies.callback);
                yield;
            }
        }
        if (added > 0) {
            Utils.sync_log (
                "imap body index deepen “%s” +%u (of %u pending)".printf (
                    folder.name,
                    added,
                    pending.length
                )
            );
        }
        return added;
    }

    public async int local_uid_count (
        Account account,
        Folder folder,
        Cancellable? cancellable = null
    ) throws Error {
        /* Last STATUS/SELECT EXISTS — avoids a network probe on every open. */
        var key = folder_key (account, folder);
        if (this.folder_exists.contains (key))
            return this.folder_exists.get (key);
        return 0;
    }

    public bool peek_folder_remote_counts (
        Account account,
        Folder folder,
        out int total,
        out int unread
    ) {
        var key = folder_key (account, folder);
        if (!this.folder_exists.contains (key)) {
            total = -1;
            unread = -1;
            return false;
        }
        total = this.folder_exists.get (key);
        unread = this.folder_unseen.contains (key)
            ? this.folder_unseen.get (key)
            : -1;
        return true;
    }

    public void unwatch_all_folders () {
        var keys = new GenericArray<string> ();
        this.idle_state_lock.lock ();
        try {
            this.idle_watches.foreach ((key, watch) => {
                keys.add (key);
            });
        } finally {
            this.idle_state_lock.unlock ();
        }
        for (uint i = 0; i < keys.length; i++)
            stop_idle_watch (keys[i]);
    }

    public GenericArray<string> apply_live_flags (
        Account account,
        Folder folder,
        GenericArray<Message> messages
    ) {
        HashTable<string, PendingFlagUpdate>? flags = null;
        GenericArray<string>? removed_pending = null;
        this.idle_state_lock.lock ();
        try {
            var watch = this.idle_watches.get (watch_key (account, folder));
            if (watch == null)
                return new GenericArray<string> ();
            if (watch.pending_flags.size () > 0) {
                flags = watch.pending_flags;
                watch.pending_flags = new HashTable<string, PendingFlagUpdate> (str_hash, str_equal);
            }
            if (watch.pending_removed.length > 0) {
                removed_pending = watch.pending_removed;
                watch.pending_removed = new GenericArray<string> ();
            }
        } finally {
            this.idle_state_lock.unlock ();
        }

        if (flags != null) {
            for (uint i = 0; i < messages.length; i++) {
                var message = messages[i];
                if (message.uid == null || message.uid.length == 0)
                    continue;
                var upd = flags.get (message.uid);
                if (upd == null)
                    continue;
                message.seen = upd.seen;
                message.flagged = upd.flagged;
            }
        }

        var removed = new GenericArray<string> ();
        if (removed_pending == null)
            return removed;
        var have = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < removed_pending.length; i++) {
            var uid = removed_pending[i];
            if (uid == null || uid.length == 0 || have.contains (uid))
                continue;
            have.set (uid, 1);
            removed.add (uid);
        }
        return removed;
    }

    public uint append_live_headers (
        Account account,
        Folder folder,
        GenericArray<Message> messages
    ) {
        GenericArray<Message>? pending = null;
        this.idle_state_lock.lock ();
        try {
            var watch = this.idle_watches.get (watch_key (account, folder));
            if (watch == null || watch.pending_headers.length == 0)
                return 0;
            pending = watch.pending_headers;
            watch.pending_headers = new GenericArray<Message> ();
        } finally {
            this.idle_state_lock.unlock ();
        }

        var have = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < messages.length; i++) {
            if (messages[i].uid != null && messages[i].uid.length > 0)
                have.set (messages[i].uid, 1);
        }

        uint added = 0;
        for (uint i = 0; i < pending.length; i++) {
            var message = pending[i];
            if (message.uid == null || message.uid.length == 0)
                continue;
            if (have.contains (message.uid))
                continue;
            have.set (message.uid, 1);
            messages.add (message);
            added++;
        }
        if (added == 0)
            return 0;
        sort_by_date_desc (messages);
        return added;
    }

    public MessageContent? peek_body (Account account, Folder folder, string uid) {
        if (uid != null && (uid.has_prefix ("local-sent-") || uid.has_prefix ("local-draft-"))) {
            var local = this.local_outgoing_bodies.get (uid);
            if (local != null)
                return local;
        }
        return this.body_ram.get (body_key (account, folder, uid));
    }

    public async MessageContent? try_load_body_from_disk (
        Account account,
        Folder folder,
        string uid,
        Cancellable? cancellable = null
    ) throws Error {
        var ram = peek_body (account, folder, uid);
        if (ram != null)
            return ram;
        if (uid != null && (uid.has_prefix ("local-sent-") || uid.has_prefix ("local-draft-"))) {
            var local_file = local_outgoing_body_file (account, uid);
            if (local_file.query_exists (cancellable)) {
                uint8[] local_data;
                yield local_file.load_contents_async (cancellable, out local_data, null);
                var local_content = content_from_rfc822 (uid, (string) local_data);
                this.local_outgoing_bodies.set (uid, local_content);
                index_body_content (account, folder, uid, local_content);
                return local_content;
            }
        }
        var file = body_file (account, folder, uid);
        if (!file.query_exists (cancellable))
            return null;
        uint8[] data;
        yield file.load_contents_async (cancellable, out data, null);
        var raw = (string) data;
        var content = content_from_rfc822 (uid, raw);
        this.body_ram.set (body_key (account, folder, uid), content);
        index_body_content (account, folder, uid, content);
        return content;
    }

    public void rekey_body (
        Account account,
        Folder from,
        string old_uid,
        Folder dest,
        string new_uid
    ) {
    }

    public async MessageContent load_message (
        Account account,
        Folder folder,
        string uid,
        Cancellable? cancellable = null
    ) throws Error {
        var cached = yield try_load_body_from_disk (account, folder, uid, cancellable);
        if (cached != null)
            return cached;

        string? raw = null;
        Error? fetch_error = null;
        SourceFunc callback = load_message.callback;
        new Thread<void*> ("letter-imap-body", () => {
            try {
                var client = open_client (account, cancellable);
                try {
                    client.select (folder.full_name, cancellable);
                    raw = client.fetch_body_uid (uid, cancellable);
                } finally {
                    client.logout (null);
                }
            } catch (Error e) {
                fetch_error = e;
            }
            Idle.add (() => {
                callback ();
                return Source.REMOVE;
            });
            return null;
        });
        yield;
        if (fetch_error != null)
            throw fetch_error;
        if (raw == null)
            throw new IOError.FAILED (_("Empty IMAP body"));

        try {
            var file = body_file (account, folder, uid);
            var parent = file.get_parent ();
            if (parent != null && !parent.query_exists (null))
                parent.make_directory_with_parents (null);
            file.replace_contents (raw.data, null, false, FileCreateFlags.PRIVATE, null, null);
        } catch (Error e) {
            warning ("ImapMailBackend: body cache write: %s", e.message);
        }

        var content = content_from_rfc822 (uid, raw);
        this.body_ram.set (body_key (account, folder, uid), content);
        index_body_content (account, folder, uid, content);
        return content;
    }

    public async void export_message_eml (
        Account account,
        Folder folder,
        string uid,
        File dest,
        Cancellable? cancellable = null
    ) throws Error {
        var content = yield load_message (account, folder, uid, cancellable);
        var text = content.plain_text ?? content.html ?? "";
        dest.replace_contents (text.data, null, false, FileCreateFlags.NONE, null, cancellable);
    }

    public void queue_mark_seen (Account account, Folder folder, string uid) {
        var uids = new GenericArray<string> ();
        uids.add (uid);
        enqueue_flag_job (account, folder, uids, "\\Seen", true);
    }

    public async void set_message_seen (
        Account account,
        Folder folder,
        string uid,
        bool seen,
        Cancellable? cancellable = null
    ) throws Error {
        var uids = new GenericArray<string> ();
        uids.add (uid);
        enqueue_flag_job (account, folder, uids, "\\Seen", seen);
    }

    public async uint prefetch_recent (
        Account account,
        Folder folder,
        GenericArray<Message> listed,
        int days,
        Cancellable? cancellable = null,
        int max_index = -1
    ) throws Error {
        if (listed.length == 0)
            return 0;

        int64 cutoff = 0;
        if (days > 0) {
            var now = new DateTime.now_local ();
            var then = now.add_days (-days);
            if (then != null)
                cutoff = then.to_unix ();
        }

        uint limit = MailSession.PREFETCH_NETWORK_CHUNK;
        var cursor_key = prefetch_cursor_key (account, folder);
        ensure_prefetch_cursors_loaded ();
        int start = 0;
        if (this.prefetch_cursor.contains (cursor_key))
            start = this.prefetch_cursor.get (cursor_key);
        if (start < 0 || start > (int) listed.length)
            start = 0;

        var window_end = (int) listed.length;
        if (max_index >= 0)
            window_end = int.min (max_index + 1, window_end);
        if (start >= window_end) {
            this.prefetch_cursor.set (cursor_key, 0);
            schedule_prefetch_cursor_save ();
            return 0;
        }

        /* Probe only — never MIME-parse / BodyTextIndex on the main thread
         * (warm Importanti ~10k froze GTK). Index after FETCH or via
         * index_more_cached_bodies. */
        var want = new GenericArray<string> ();
        int i = start;
        uint skipped_disk = 0;
        var hit_cutoff = false;
        for (; i < window_end && want.length < limit; i++) {
            if (cancellable != null && cancellable.is_cancelled ())
                break;
            var message = listed[i];
            if (message.uid == null || message.uid.length == 0 || message.local_only)
                continue;
            if (cutoff > 0 && message.date > 0 && message.date < cutoff) {
                hit_cutoff = true;
                break;
            }
            if (peek_body (account, folder, message.uid) != null) {
                skipped_disk++;
                continue;
            }
            if (body_file (account, folder, message.uid).query_exists (null)) {
                skipped_disk++;
                continue;
            }
            want.add (message.uid);
        }

        var reached_end = hit_cutoff || i >= window_end
            || (cancellable != null && cancellable.is_cancelled ());
        /* Advance past disk/RAM hits even when this chunk needs no FETCH. */
        if (want.length == 0) {
            var next_empty = reached_end ? 0 : i;
            this.prefetch_cursor.set (cursor_key, next_empty);
            schedule_prefetch_cursor_save ();
            if (start > 0 || skipped_disk > 0) {
                Utils.sync_log (
                    "imap prefetch “%s” cursor=%d/%d skipped-disk=%u (no fetch)".printf (
                        folder.name,
                        next_empty,
                        window_end,
                        skipped_disk
                    )
                );
            }
            return 0;
        }

        uint fetched = 0;
        Error? prefetch_error = null;
        SourceFunc callback = prefetch_recent.callback;
        var fold = folder;
        var acc = account;
        new Thread<void*> ("letter-imap-prefetch", () => {
            try {
                var client = open_client (acc, cancellable);
                try {
                    client.select (fold.full_name, cancellable);
                    for (uint w = 0; w < want.length; w++) {
                        if (cancellable != null && cancellable.is_cancelled ())
                            break;
                        var uid = want[w];
                        try {
                            var raw = client.fetch_body_uid (uid, cancellable);
                            if (raw == null || raw.length == 0)
                                continue;
                            try {
                                var file = body_file (acc, fold, uid);
                                var parent = file.get_parent ();
                                if (parent != null && !parent.query_exists (null))
                                    parent.make_directory_with_parents (null);
                                file.replace_contents (
                                    raw.data,
                                    null,
                                    false,
                                    FileCreateFlags.PRIVATE,
                                    null,
                                    null
                                );
                            } catch (Error e) {
                                warning ("ImapMailBackend prefetch write %s: %s", uid, e.message);
                            }
                            var content = content_from_rfc822 (uid, raw);
                            Idle.add (() => {
                                this.body_ram.set (body_key (acc, fold, uid), content);
                                index_body_content (acc, fold, uid, content);
                                return Source.REMOVE;
                            });
                            fetched++;
                        } catch (Error e) {
                            if (e is IOError.CANCELLED)
                                throw e;
                            warning ("ImapMailBackend prefetch %s: %s", uid, e.message);
                        }
                    }
                } finally {
                    client.logout (null);
                }
            } catch (Error e) {
                prefetch_error = e;
            }
            Idle.add (() => {
                callback ();
                return Source.REMOVE;
            });
            return null;
        });
        yield;
        if (prefetch_error != null)
            throw prefetch_error;

        /* Cancel mid-chunk keeps cursor at i so resume retries missing UIDs
         * after ones already on disk. */
        reached_end = hit_cutoff || i >= window_end;
        var next_cursor = reached_end ? 0 : i;
        this.prefetch_cursor.set (cursor_key, next_cursor);
        schedule_prefetch_cursor_save ();

        Utils.sync_log (
            "imap prefetch “%s” fetched=%u want=%u skipped-disk=%u cursor=%d/%d days=%d%s".printf (
                folder.name,
                fetched,
                want.length,
                skipped_disk,
                next_cursor,
                window_end,
                days,
                reached_end ? " (window complete)" : ""
            )
        );
        return fetched;
    }

    public void reset_prefetch_progress (Account? account = null) {
        ensure_prefetch_cursors_loaded ();
        if (account == null) {
            this.prefetch_cursor.remove_all ();
            delete_prefetch_cursor_file ();
            return;
        }
        var account_safe = Checksum.compute_for_string (
            ChecksumType.SHA256,
            account.source_uid ?? account.uid
        );
        var prefix = account_safe + ":";
        var keys = new GenericArray<string> ();
        this.prefetch_cursor.foreach ((key, value) => {
            if (key.has_prefix (prefix))
                keys.add (key);
        });
        for (uint k = 0; k < keys.length; k++)
            this.prefetch_cursor.remove (keys[k]);
        schedule_prefetch_cursor_save ();
    }

    public void flush_prefetch_progress () {
        if (this.prefetch_cursor_save_source != 0) {
            Source.remove (this.prefetch_cursor_save_source);
            this.prefetch_cursor_save_source = 0;
        }
        if (this.prefetch_cursors_loaded)
            save_prefetch_cursors ();
    }

    private static string prefetch_cursor_key (Account account, Folder folder) {
        var account_id = account.source_uid ?? account.uid;
        var account_safe = Checksum.compute_for_string (ChecksumType.SHA256, account_id);
        var folder_safe = Checksum.compute_for_string (ChecksumType.SHA256, folder.full_name);
        return "%s:%s".printf (account_safe, folder_safe);
    }

    private void ensure_prefetch_cursors_loaded () {
        if (this.prefetch_cursors_loaded)
            return;
        this.prefetch_cursors_loaded = true;
        var path = MailSession.prefetch_cursor_cache_file ();
        if (!FileUtils.test (path, FileTest.IS_REGULAR))
            return;
        try {
            var key = new KeyFile ();
            key.load_from_file (path, KeyFileFlags.NONE);
            if (!key.has_group ("cursors"))
                return;
            foreach (var entry in key.get_keys ("cursors"))
                this.prefetch_cursor.set (entry, key.get_integer ("cursors", entry));
        } catch (Error e) {
            debug ("ImapMailBackend: could not read prefetch cursors: %s", e.message);
        }
    }

    private void schedule_prefetch_cursor_save () {
        if (this.prefetch_cursor_save_source != 0)
            return;
        this.prefetch_cursor_save_source = Timeout.add (1500, () => {
            this.prefetch_cursor_save_source = 0;
            save_prefetch_cursors ();
            return Source.REMOVE;
        });
    }

    private void save_prefetch_cursors () {
        try {
            File.new_for_path (MailSession.prefetch_cursor_cache_dir ()).make_directory_with_parents ();
        } catch (Error e) {
            if (!(e is IOError.EXISTS)) {
                debug ("ImapMailBackend: prefetch cursor dir: %s", e.message);
                return;
            }
        }
        var key = new KeyFile ();
        this.prefetch_cursor.foreach ((ck, value) => {
            key.set_integer ("cursors", ck, value);
        });
        try {
            key.save_to_file (MailSession.prefetch_cursor_cache_file ());
        } catch (Error e) {
            debug ("ImapMailBackend: could not write prefetch cursors: %s", e.message);
        }
    }

    private static void delete_prefetch_cursor_file () {
        try {
            File.new_for_path (MailSession.prefetch_cursor_cache_file ()).delete ();
        } catch (Error e) {
            if (!(e is IOError.NOT_FOUND))
                debug ("ImapMailBackend: could not delete prefetch cursors: %s", e.message);
        }
    }

    public void release_transient_memory () {
        this.body_ram.remove_all ();
    }

    public void relieve_memory_pressure () {
        release_transient_memory ();
    }

    public async string copy_message (
        Account account,
        Folder from,
        string uid,
        Folder destination,
        Cancellable? cancellable = null
    ) throws Error {
        var uids = new GenericArray<string> ();
        uids.add (uid);
        yield run_on_imap_thread (() => {
            var client = open_client (account, cancellable);
            try {
                client.select (from.full_name, cancellable);
                client.uid_copy (uids, destination.full_name, cancellable);
            } finally {
                client.logout (null);
            }
        });
        return uid;
    }

    public void enqueue_move_messages (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        GenericArray<Message>? messages
    ) {
        if (uids.length == 0)
            return;
        enqueue_transfer_job (account, from, destination, uids, true);
    }

    public void cancel_queued_moves (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        bool delete_original = true
    ) {
        if (uids.length == 0)
            return;
        var drop = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < uids.length; i++)
            drop.set (uids[i], 1);
        for (uint i = 0; i < this.transfer_queue.length; ) {
            var job = this.transfer_queue[i];
            if ((job.account.source_uid ?? job.account.uid) != (account.source_uid ?? account.uid)
                || job.from.full_name != from.full_name
                || job.destination.full_name != destination.full_name
                || job.delete_original != delete_original) {
                i++;
                continue;
            }
            var kept = new GenericArray<string> ();
            for (uint u = 0; u < job.uids.length; u++) {
                if (!drop.contains (job.uids[u]))
                    kept.add (job.uids[u]);
                else
                    unretire_moved_uid (account, from, job.uids[u]);
            }
            if (kept.length == 0)
                this.transfer_queue.remove_index (i);
            else {
                job.uids = kept;
                i++;
            }
        }
        schedule_registry_save ();
    }

    public void enqueue_copy_messages (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        GenericArray<Message>? messages
    ) {
        if (uids.length == 0)
            return;
        enqueue_transfer_job (account, from, destination, uids, false);
    }

    public void flush_pending_local_changes () {
        flush_pending_local_changes_async.begin ();
    }

    public bool has_blocking_local_flushes () {
        return has_pending_local_flushes ();
    }

    public void unpark_heavy_transfers () {
    }

    public async bool flush_pending_local_changes_with_timeout (uint seconds) {
        var done = false;
        var timed_out = false;
        var cancellable = new Cancellable ();
        uint timeout_id = 0;
        if (seconds > 0) {
            timeout_id = Timeout.add_seconds (seconds, () => {
                timed_out = true;
                cancellable.cancel ();
                timeout_id = 0;
                return Source.REMOVE;
            });
        }
        try {
            yield flush_queues_async (cancellable);
            done = !has_pending_local_flushes ();
        } catch (Error e) {
            if (!(e is IOError.CANCELLED))
                warning ("ImapMailBackend flush: %s", e.message);
            done = false;
        }
        if (timeout_id != 0)
            Source.remove (timeout_id);
        if (timed_out || !done)
            persist_mutation_registry_now ();
        else
            clear_registry_file ();
        return done && !timed_out;
    }

    public void persist_mutation_registry_now () {
        if (this.registry_save_source != 0) {
            Source.remove (this.registry_save_source);
            this.registry_save_source = 0;
        }
        if (!has_pending_local_flushes ()) {
            clear_registry_file ();
            return;
        }
        try {
            File.new_for_path (imap_registry_dir ()).make_directory_with_parents ();
        } catch (Error e) {
            if (!(e is IOError.EXISTS)) {
                warning ("ImapMailBackend registry dir: %s", e.message);
                return;
            }
        }
        var key = new KeyFile ();
        key.set_integer ("meta", "version", 1);
        key.set_integer ("meta", "flags", (int) this.flag_queue.length);
        key.set_integer ("meta", "transfers", (int) this.transfer_queue.length);
        for (uint i = 0; i < this.flag_queue.length; i++) {
            var job = this.flag_queue[i];
            var group = "flag-%u".printf (i);
            key.set_string (group, "account", job.account.source_uid ?? job.account.uid);
            key.set_string (group, "folder", job.folder.full_name);
            key.set_string (group, "folder_name", job.folder.name ?? "");
            key.set_string (group, "flag", job.flag_atom);
            key.set_boolean (group, "add", job.add);
            key.set_string_list (group, "uids", uids_to_array (job.uids));
        }
        for (uint i = 0; i < this.transfer_queue.length; i++) {
            var job = this.transfer_queue[i];
            var group = "transfer-%u".printf (i);
            key.set_string (group, "account", job.account.source_uid ?? job.account.uid);
            key.set_string (group, "from", job.from.full_name);
            key.set_string (group, "from_name", job.from.name ?? "");
            key.set_string (group, "destination", job.destination.full_name);
            key.set_string (group, "destination_name", job.destination.name ?? "");
            key.set_boolean (group, "delete_original", job.delete_original);
            key.set_string_list (group, "uids", uids_to_array (job.uids));
        }
        try {
            key.save_to_file (imap_registry_file ());
            Utils.sync_log ("imap mutation registry saved (%u flags, %u transfers)".printf (
                this.flag_queue.length,
                this.transfer_queue.length
            ));
        } catch (Error e) {
            warning ("ImapMailBackend registry write: %s", e.message);
        }
    }

    public uint load_mutation_registry () {
        if (this.registry_loaded)
            return 0;
        this.registry_loaded = true;
        var path = imap_registry_file ();
        if (!FileUtils.test (path, FileTest.IS_REGULAR))
            return 0;
        KeyFile key;
        try {
            key = new KeyFile ();
            key.load_from_file (path, KeyFileFlags.NONE);
        } catch (Error e) {
            warning ("ImapMailBackend registry read: %s", e.message);
            return 0;
        }
        uint loaded = 0;
        try {
            var flag_n = key.get_integer ("meta", "flags");
            for (int i = 0; i < flag_n; i++) {
                var group = "flag-%d".printf (i);
                var account_id = key.get_string (group, "account");
                var account = account_by_id (account_id);
                if (account == null)
                    continue;
                var folder = new Folder () {
                    name = key.get_string (group, "folder_name"),
                    full_name = key.get_string (group, "folder"),
                };
                var uids = string_list_to_uids (key.get_string_list (group, "uids"));
                if (uids.length == 0)
                    continue;
                this.flag_queue.add (new FlagJob () {
                    account = account,
                    folder = folder,
                    uids = uids,
                    flag_atom = key.get_string (group, "flag"),
                    add = key.get_boolean (group, "add"),
                });
                this.folders_pending_flags.set (folder_key (account, folder), 1);
                loaded++;
            }
            var transfer_n = key.get_integer ("meta", "transfers");
            for (int i = 0; i < transfer_n; i++) {
                var group = "transfer-%d".printf (i);
                var account_id = key.get_string (group, "account");
                var account = account_by_id (account_id);
                if (account == null)
                    continue;
                var from = new Folder () {
                    name = key.get_string (group, "from_name"),
                    full_name = key.get_string (group, "from"),
                };
                var destination = new Folder () {
                    name = key.get_string (group, "destination_name"),
                    full_name = key.get_string (group, "destination"),
                };
                var uids = string_list_to_uids (key.get_string_list (group, "uids"));
                if (uids.length == 0)
                    continue;
                this.transfer_queue.add (new TransferJob () {
                    account = account,
                    from = from,
                    destination = destination,
                    uids = uids,
                    delete_original = key.get_boolean (group, "delete_original"),
                });
                for (uint u = 0; u < uids.length; u++)
                    retire_moved_uid (account, from, uids[u]);
                loaded++;
            }
        } catch (Error e) {
            warning ("ImapMailBackend registry parse: %s", e.message);
        }
        if (loaded > 0)
            Utils.sync_log ("imap mutation registry loaded %u job(s)".printf (loaded));
        return loaded;
    }

    public void foreach_queued_move_hide (QueuedMoveHideFunc func) {
        for (uint i = 0; i < this.transfer_queue.length; i++) {
            var job = this.transfer_queue[i];
            if (!job.delete_original)
                continue;
            for (uint u = 0; u < job.uids.length; u++)
                func (job.account, job.from, job.uids[u]);
        }
    }

    public bool has_pending_local_flushes () {
        return this.flag_queue.length > 0 || this.transfer_queue.length > 0;
    }

    public async void flush_pending_local_changes_async () {
        try {
            yield flush_queues_async (null);
            if (!has_pending_local_flushes ())
                clear_registry_file ();
            else
                persist_mutation_registry_now ();
        } catch (Error e) {
            warning ("ImapMailBackend flush async: %s", e.message);
            persist_mutation_registry_now ();
        }
    }

    public async void delete_message (
        Account account,
        Folder folder,
        string uid,
        Folder? trash,
        Cancellable? cancellable = null
    ) throws Error {
        var uids = new GenericArray<string> ();
        uids.add (uid);
        if (trash != null && trash.full_name != folder.full_name) {
            enqueue_transfer_job (account, folder, trash, uids, true);
            return;
        }

        this.local_outgoing_bodies.remove (uid);
        try {
            local_outgoing_body_file (account, uid).delete (null);
        } catch (Error e) {
        }
        try {
            body_file (account, folder, uid).delete (null);
        } catch (Error e) {
        }
        this.body_ram.remove (body_key (account, folder, uid));

        if (uid.has_prefix ("local-draft-") || uid.has_prefix ("local-sent-")) {
            if (folder.kind == FolderKind.DRAFTS)
                draft_removed (account, folder, uid);
            return;
        }

        yield run_on_imap_thread (() => {
            var client = open_client (account, cancellable);
            try {
                client.select (folder.full_name, cancellable);
                client.uid_store_flags (uids, "\\Deleted", true, cancellable);
                try {
                    client.expunge (cancellable);
                } catch (Error e) {
                    warning ("EXPUNGE: %s", e.message);
                }
            } finally {
                client.logout (null);
            }
        });
        if (folder.kind == FolderKind.DRAFTS)
            draft_removed (account, folder, uid);
    }

    public async void delete_message_local (
        Account account,
        Folder folder,
        string uid
    ) throws Error {
        retire_moved_uid (account, folder, uid);
        this.local_outgoing_bodies.remove (uid);
        if (folder.kind == FolderKind.DRAFTS)
            draft_removed (account, folder, uid);
    }

    public async void delete_uids (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        Folder? trash
    ) throws Error {
        if (uids.length == 0)
            return;
        if (trash != null && trash.full_name != folder.full_name)
            enqueue_transfer_job (account, folder, trash, uids, true);
        else {
            for (uint i = 0; i < uids.length; i++)
                drop_body_files (account, folder, uids[i]);
            yield run_on_imap_thread (() => {
                var client = open_client (account, null);
                try {
                    client.select (folder.full_name, null);
                    client.uid_store_flags (uids, "\\Deleted", true, null);
                    client.expunge (null);
                } finally {
                    client.logout (null);
                }
            });
        }
    }

    public async void empty_folder (Account account, Folder folder) throws Error {
        if (folder.is_virtual_view || folder.is_gmail_namespace)
            return;

        uint purged = 0;
        yield run_on_imap_thread (() => {
            var client = open_client (account, null);
            try {
                var exists = client.select (folder.full_name, null);
                if (exists > 0) {
                    client.store_all_deleted (null);
                    client.expunge (null);
                }
                this.folder_exists.set (folder_key (account, folder), 0);
                this.folder_unseen.set (folder_key (account, folder), 0);
            } finally {
                client.logout (null);
            }
        });
        purged = wipe_folder_body_dir (account, folder);
        this.body_text_index.forget_folder (account.source_uid ?? account.uid, folder.full_name);
        folder.unread = 0;
        folder.total = 0;
        Utils.sync_log (
            "imap empty “%s” — wiped %u body file(s)".printf (folder.name, purged)
        );
    }

    public async void set_folder_seen (Account account, Folder folder, bool seen) throws Error {
        /* Slice: mark-all not yet; Window uses set_uids_seen with listed UIDs. */
    }

    public async void set_uids_seen (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        bool seen
    ) throws Error {
        enqueue_flag_job (account, folder, uids, "\\Seen", seen);
    }

    public async void set_uids_flagged (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        bool flagged
    ) throws Error {
        enqueue_flag_job (account, folder, uids, "\\Flagged", flagged);
    }

    public bool folder_has_pending_flags (Account account, Folder folder) {
        return this.folders_pending_flags.contains (folder_key (account, folder));
    }

    public async void create_mailbox_folder (
        Account account,
        Folder parent,
        string name
    ) throws Error {
        throw not_supported ("create folder");
    }

    public async void rename_mailbox_folder (
        Account account,
        Folder folder,
        string new_full_name
    ) throws Error {
        throw not_supported ("rename folder");
    }

    public async void delete_mailbox_folder (
        Account account,
        Folder folder
    ) throws Error {
        throw not_supported ("delete folder");
    }

    public void retire_moved_uid (Account account, Folder folder, string uid) {
        this.retired_uids.set (retire_key (account, folder, uid), 1);
    }

    public void unretire_moved_uid (Account account, Folder folder, string uid) {
        this.retired_uids.remove (retire_key (account, folder, uid));
    }

    public GenericArray<Message> without_retired_moves (
        Account account,
        Folder folder,
        GenericArray<Message> messages
    ) {
        var out = new GenericArray<Message> ();
        for (uint i = 0; i < messages.length; i++) {
            var message = messages[i];
            if (message.uid != null
                && this.retired_uids.contains (retire_key (account, folder, message.uid)))
                continue;
            out.add (message);
        }
        return out;
    }

    private static string retire_key (Account account, Folder folder, string uid) {
        return "%s\n%s\n%s".printf (account.source_uid ?? account.uid, folder.full_name, uid);
    }

    private void enqueue_flag_job (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        string flag_atom,
        bool add
    ) {
        if (uids.length == 0)
            return;
        /* Merge into an existing same-route job. */
        for (uint i = 0; i < this.flag_queue.length; i++) {
            var job = this.flag_queue[i];
            if ((job.account.source_uid ?? job.account.uid) != (account.source_uid ?? account.uid)
                || job.folder.full_name != folder.full_name
                || job.flag_atom != flag_atom
                || job.add != add)
                continue;
            var have = new HashTable<string, uint8> (str_hash, str_equal);
            for (uint u = 0; u < job.uids.length; u++)
                have.set (job.uids[u], 1);
            for (uint u = 0; u < uids.length; u++) {
                if (!have.contains (uids[u]))
                    job.uids.add (uids[u]);
            }
            this.folders_pending_flags.set (folder_key (account, folder), 1);
            schedule_registry_save ();
            return;
        }
        var copy = new GenericArray<string> ();
        for (uint i = 0; i < uids.length; i++)
            copy.add (uids[i]);
        this.flag_queue.add (new FlagJob () {
            account = account,
            folder = folder,
            uids = copy,
            flag_atom = flag_atom,
            add = add,
        });
        this.folders_pending_flags.set (folder_key (account, folder), 1);
        schedule_registry_save ();
        Utils.sync_log ("imap flag deferred %s %s %u uid(s) in “%s”".printf (
            add ? "+" : "-",
            flag_atom,
            copy.length,
            folder.name
        ));
    }

    private void enqueue_transfer_job (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        bool delete_original
    ) {
        for (uint i = 0; i < this.transfer_queue.length; i++) {
            var job = this.transfer_queue[i];
            if ((job.account.source_uid ?? job.account.uid) != (account.source_uid ?? account.uid)
                || job.from.full_name != from.full_name
                || job.destination.full_name != destination.full_name
                || job.delete_original != delete_original)
                continue;
            var have = new HashTable<string, uint8> (str_hash, str_equal);
            for (uint u = 0; u < job.uids.length; u++)
                have.set (job.uids[u], 1);
            for (uint u = 0; u < uids.length; u++) {
                if (have.contains (uids[u]))
                    continue;
                job.uids.add (uids[u]);
                if (delete_original)
                    retire_moved_uid (account, from, uids[u]);
            }
            schedule_registry_save ();
            return;
        }
        var copy = new GenericArray<string> ();
        for (uint i = 0; i < uids.length; i++) {
            copy.add (uids[i]);
            if (delete_original)
                retire_moved_uid (account, from, uids[i]);
        }
        this.transfer_queue.add (new TransferJob () {
            account = account,
            from = from,
            destination = destination,
            uids = copy,
            delete_original = delete_original,
        });
        schedule_registry_save ();
        Utils.sync_log ("imap move deferred “%s” → “%s” %u uid(s)".printf (
            from.name,
            destination.name,
            copy.length
        ));
    }

    private void schedule_registry_save () {
        if (this.registry_save_source != 0)
            Source.remove (this.registry_save_source);
        this.registry_save_source = Timeout.add (400, () => {
            this.registry_save_source = 0;
            persist_mutation_registry_now ();
            return Source.REMOVE;
        });
    }

    private static string imap_registry_dir () {
        return Path.build_filename (
            Environment.get_user_data_dir (),
            "letter",
            "mutation-registry"
        );
    }

    private static string imap_registry_file () {
        return Path.build_filename (imap_registry_dir (), "pending-imap");
    }

    private void clear_registry_file () {
        var path = imap_registry_file ();
        if (!FileUtils.test (path, FileTest.IS_REGULAR))
            return;
        if (FileUtils.remove (path) == 0)
            Utils.sync_log ("imap mutation registry cleared");
    }

    private static string[] uids_to_array (GenericArray<string> uids) {
        var arr = new string[uids.length];
        for (uint i = 0; i < uids.length; i++)
            arr[i] = uids[i];
        return arr;
    }

    private static GenericArray<string> string_list_to_uids (string[] list) {
        var uids = new GenericArray<string> ();
        for (uint i = 0; i < list.length; i++) {
            if (list[i] != null && list[i].length > 0)
                uids.add (list[i]);
        }
        return uids;
    }

    private Account? account_by_id (string account_id) {
        IdentityAccount? id_acc = null;
        for (uint i = 0; i < this.catalog.accounts.length; i++) {
            var acc = this.catalog.accounts[i];
            if (acc.id == account_id || acc.email == account_id) {
                id_acc = acc;
                break;
            }
        }
        if (id_acc == null)
            return null;
        /* Prefer IdentityAccount.to_account () so kind/host mapping stays one place. */
        return id_acc.to_account ();
    }

    private delegate void ImapWork () throws Error;

    private async void run_on_imap_thread (owned ImapWork work) throws Error {
        Error? error = null;
        SourceFunc callback = run_on_imap_thread.callback;
        new Thread<void*> ("letter-imap-mut", () => {
            try {
                work ();
            } catch (Error e) {
                error = e;
            }
            Idle.add (() => {
                callback ();
                return Source.REMOVE;
            });
            return null;
        });
        yield;
        if (error != null)
            throw error;
    }

    private async void flush_queues_async (Cancellable? cancellable) throws Error {
        if (this.flush_running)
            return;
        this.flush_running = true;
        try {
            while (this.flag_queue.length > 0) {
                if (cancellable != null && cancellable.is_cancelled ())
                    throw new IOError.CANCELLED ("Cancelled");
                var job = this.flag_queue[0];
                yield run_on_imap_thread (() => {
                    var client = open_client (job.account, cancellable);
                    try {
                        client.select (job.folder.full_name, cancellable);
                        client.uid_store_flags (job.uids, job.flag_atom, job.add, cancellable);
                    } finally {
                        client.logout (null);
                    }
                });
                this.flag_queue.remove_index (0);
                maybe_clear_folder_pending_flags (job.account, job.folder);
                Utils.sync_log ("imap flag flushed %s %s %u in “%s”".printf (
                    job.add ? "+" : "-",
                    job.flag_atom,
                    job.uids.length,
                    job.folder.name
                ));
            }
            while (this.transfer_queue.length > 0) {
                if (cancellable != null && cancellable.is_cancelled ())
                    throw new IOError.CANCELLED ("Cancelled");
                var job = this.transfer_queue[0];
                var chunk = new GenericArray<string> ();
                uint limit = uint.min (job.uids.length, 25);
                for (uint i = 0; i < limit; i++)
                    chunk.add (job.uids[i]);
                yield run_on_imap_thread (() => {
                    var client = open_client (job.account, cancellable);
                    try {
                        client.select (job.from.full_name, cancellable);
                        if (job.delete_original)
                            client.uid_move (chunk, job.destination.full_name, cancellable);
                        else
                            client.uid_copy (chunk, job.destination.full_name, cancellable);
                    } finally {
                        client.logout (null);
                    }
                });
                for (uint i = 0; i < chunk.length; i++) {
                    unretire_moved_uid (job.account, job.from, chunk[i]);
                    if (job.delete_original)
                        drop_body_files (job.account, job.from, chunk[i]);
                    /* Drop flushed UIDs from the front. */
                    job.uids.remove_index (0);
                }
                if (job.uids.length == 0)
                    this.transfer_queue.remove_index (0);
                Utils.sync_log ("imap transfer flushed “%s” → “%s” %u (left %u)".printf (
                    job.from.name,
                    job.destination.name,
                    chunk.length,
                    job.uids.length
                ));
            }
        } finally {
            this.flush_running = false;
        }
    }

    private void maybe_clear_folder_pending_flags (Account account, Folder folder) {
        var key = folder_key (account, folder);
        for (uint i = 0; i < this.flag_queue.length; i++) {
            var job = this.flag_queue[i];
            if ((job.account.source_uid ?? job.account.uid) == (account.source_uid ?? account.uid)
                && job.folder.full_name == folder.full_name)
                return;
        }
        this.folders_pending_flags.remove (key);
    }

    public Identity? get_identity (Account account) {
        var id_acc = find_identity (account);
        if (id_acc == null)
            return null;
        return new Identity () {
            name = id_acc.effective_sender_name (),
            address = id_acc.email,
            aliases = {},
        };
    }

    public void ensure_can_send (
        Account account,
        string to,
        string? cc,
        string? bcc
    ) throws Error {
        if (find_identity (account) == null) {
            throw new IOError.FAILED (_("This account has no sending identity."));
        }
        var to_list = LetterSmtp.MimeBuilder.parse_address_list (to);
        if (to_list.length == 0) {
            throw new IOError.INVALID_ARGUMENT (_("Add at least one recipient."));
        }
        ensure_valid_smtp_recipients (to_list);
        ensure_valid_smtp_recipients (LetterSmtp.MimeBuilder.parse_address_list (cc));
        ensure_valid_smtp_recipients (LetterSmtp.MimeBuilder.parse_address_list (bcc));
    }

    public async void send_message (
        Account account,
        string to,
        string? cc,
        string subject,
        string body,
        string? html = null,
        string? bcc = null,
        GenericArray<Attachment>? attachments = null,
        MessageContent? reply_of = null,
        Cancellable? cancellable = null,
        bool is_forward = false,
        bool high_priority = false
    ) throws Error {
        ensure_can_send (account, to, cc, bcc);
        var id_acc = find_identity (account);
        if (id_acc == null) {
            throw new IOError.FAILED (_("This account has no sending identity."));
        }
        var identity = get_identity (account);
        if (identity == null) {
            throw new IOError.FAILED (_("This account has no sending identity."));
        }

        var rfc822 = build_outgoing_rfc822 (
            identity, to, cc, bcc, subject, body, html, attachments, reply_of, is_forward, high_priority
        );
        var to_list = LetterSmtp.MimeBuilder.parse_address_list (to);
        var cc_list = LetterSmtp.MimeBuilder.parse_address_list (cc);
        var bcc_list = LetterSmtp.MimeBuilder.parse_address_list (bcc);
        var recipients = new GenericArray<string> ();
        for (uint i = 0; i < to_list.length; i++)
            recipients.add (LetterSmtp.MimeBuilder.extract_email (to_list[i]));
        for (uint i = 0; i < cc_list.length; i++)
            recipients.add (LetterSmtp.MimeBuilder.extract_email (cc_list[i]));
        for (uint i = 0; i < bcc_list.length; i++)
            recipients.add (LetterSmtp.MimeBuilder.extract_email (bcc_list[i]));

        var smtp_host = resolve_smtp_host (id_acc);
        uint16 smtp_port = (uint16) (id_acc.smtp_port > 0 ? id_acc.smtp_port : 465);
        var starttls = smtp_port == 587;
        var user = id_acc.username ?? id_acc.email;
        string? password = null;
        string? access = null;
        if (id_acc.uses_oauth2 ()) {
            access = IdentityOAuth.ensure_access_token_sync (id_acc);
        } else {
            password = IdentitySecrets.lookup_password (id_acc.id);
            if (password == null || password.length == 0) {
                throw new IOError.NOT_FOUND (
                    _("No password in libsecret for “%s”.").printf (id_acc.email)
                );
            }
        }

        send_starting ();
        try {
            var pass_copy = password;
            var token_copy = access;
            yield run_on_imap_thread (() => {
                var smtp = new LetterSmtp.Client ();
                try {
                    smtp.connect_host (smtp_host, smtp_port, starttls, cancellable);
                    smtp.ehlo (smtp_host, cancellable);
                    if (token_copy != null)
                        smtp.auth_xoauth2 (user, token_copy, cancellable);
                    else
                        smtp.auth_login (user, pass_copy, cancellable);
                    smtp.send_mail (identity.address, recipients, rfc822, cancellable);
                } finally {
                    smtp.quit (null);
                }
            });
            Utils.sync_log ("imap smtp send ok to=%s via %s:%u".printf (
                to, smtp_host, smtp_port
            ));
        } finally {
            if (password != null)
                Secret.password_wipe (password);
            send_finished ();
        }

        /* Outbox must clear as soon as SMTP accepts the message. Gmail already
         * files Sent via SMTP; APPEND is best-effort and must not block/hang. */
        var sent_account = account;
        var sent_id = id_acc;
        var sent_rfc822 = rfc822;
        Idle.add (() => {
            append_to_sent_folder.begin (sent_account, sent_id, sent_rfc822, null);
            return Source.REMOVE;
        });

        /* Cache-first: paint Sent immediately (Window.on_message_sent). */
        var local_uid = "local-sent-%lld".printf (new DateTime.now_utc ().to_unix ());
        var sent = message_from_outgoing_rfc822 (
            local_uid, rfc822, identity, to, cc, subject, body, attachments, reply_of,
            high_priority, true, true
        );
        var content = content_from_rfc822 (local_uid, rfc822);
        this.local_outgoing_bodies.set (local_uid, content);
        try {
            var file = local_outgoing_body_file (account, local_uid);
            var parent = file.get_parent ();
            if (parent != null && !parent.query_exists (null))
                parent.make_directory_with_parents (null);
            file.replace_contents (rfc822.data, null, false, FileCreateFlags.PRIVATE, null, null);
        } catch (Error e) {
            warning ("ImapMailBackend local sent body: %s", e.message);
        }
        message_sent (account, sent);
    }

    private static void ensure_valid_smtp_recipients (GenericArray<string> list) throws Error {
        for (uint i = 0; i < list.length; i++) {
            var email = LetterSmtp.MimeBuilder.extract_email (list[i]);
            if (email.index_of_char ('@') <= 0) {
                throw new IOError.INVALID_ARGUMENT (
                    _("Invalid recipient: %s").printf (list[i])
                );
            }
        }
    }

    private static string resolve_smtp_host (IdentityAccount acc) {
        if (acc.smtp_host != null && acc.smtp_host.strip ().length > 0)
            return acc.smtp_host.strip ();
        var imap = acc.imap_host ?? "";
        if (imap.has_prefix ("imap."))
            return "smtp." + imap.substring (5);
        if (imap.length > 0)
            return imap;
        return "smtp.gmail.com";
    }

    private static string? angle_msgid (string? raw) {
        if (raw == null || raw.strip ().length == 0)
            return null;
        var s = raw.strip ();
        if (s.has_prefix ("<") && s.has_suffix (">"))
            return s;
        return "<%s>".printf (s);
    }

    private async void append_to_sent_folder (
        Account account,
        IdentityAccount id_acc,
        string rfc822,
        Cancellable? cancellable
    ) throws Error {
        /* Prefer localized Gmail Sent; fall back to common names. */
        string[] candidates = {
            "[Gmail]/Posta inviata",
            "[Gmail]/Sent Mail",
            "Sent",
            "INBOX.Sent",
        };
        yield run_on_imap_thread (() => {
            var client = open_client (account, cancellable);
            try {
                Error? last = null;
                for (uint i = 0; i < candidates.length; i++) {
                    try {
                        client.append_rfc822 (candidates[i], rfc822, "\\Seen", cancellable);
                        Utils.sync_log ("imap Sent APPEND → %s".printf (candidates[i]));
                        return;
                    } catch (Error e) {
                        last = e;
                    }
                }
                if (last != null)
                    throw last;
            } finally {
                client.logout (null);
            }
        });
    }

    public async Message? save_draft (
        Account account,
        string to,
        string? cc,
        string subject,
        string body,
        string? html = null,
        string? bcc = null,
        GenericArray<Attachment>? attachments = null,
        MessageContent? reply_of = null,
        bool is_forward = false,
        bool high_priority = false,
        Cancellable? cancellable = null,
        string? replace_uid = null,
        Folder? replace_folder = null,
        out Folder? drafts_folder
    ) throws Error {
        drafts_folder = null;
        var identity = get_identity (account);
        if (identity == null) {
            throw new IOError.FAILED (_("This account has no sending identity."));
        }

        /* Never block compose: resolve from LIST cache / Gmail default only. */
        var drafts = resolve_drafts_folder_fast (account);
        drafts_folder = drafts;

        var rfc822 = build_outgoing_rfc822 (
            identity, to, cc, bcc, subject, body, html, attachments, reply_of, is_forward, high_priority
        );

        /* Cache-first: always return a local draft so compose can close.
         * Server APPEND runs with a wall-clock timeout in the background. */
        var local_uid = "local-draft-%lld".printf (new DateTime.now_utc ().to_unix ());
        var draft = message_from_outgoing_rfc822 (
            local_uid, rfc822, identity, to, cc, subject, body, attachments, reply_of,
            high_priority, true, true
        );
        draft.folder_name = drafts.name;
        draft.folder_full_name = drafts.full_name;

        var content = content_from_rfc822 (local_uid, rfc822);
        this.local_outgoing_bodies.set (local_uid, content);
        try {
            var file = local_outgoing_body_file (account, local_uid);
            var parent = file.get_parent ();
            if (parent != null && !parent.query_exists (null))
                parent.make_directory_with_parents (null);
            file.replace_contents (rfc822.data, null, false, FileCreateFlags.PRIVATE, null, null);
        } catch (Error e) {
            warning ("ImapMailBackend local draft body: %s", e.message);
        }

        if (replace_uid != null && replace_uid.length > 0 && replace_uid != local_uid) {
            cancel_draft_append (replace_uid);
            var old_folder = replace_folder ?? drafts;
            var purge_uids = draft_uids_to_purge (replace_uid);
            for (uint i = 0; i < purge_uids.length; i++) {
                try {
                    yield purge_replaced_draft (account, old_folder, purge_uids[i], cancellable);
                } catch (Error e) {
                    warning ("Could not replace previous draft %s: %s", purge_uids[i], e.message);
                }
            }
        }

        draft_saved (account, draft, replace_uid);
        Utils.sync_log ("imap draft local “%s” — server APPEND queued".printf (drafts.full_name));

        var acc = account;
        var folder = drafts;
        var raw = rfc822;
        var pending_local = local_uid;
        var append_cancel = new Cancellable ();
        this.draft_append_cancels.set (local_uid, append_cancel);
        Idle.add (() => {
            push_draft_append.begin (acc, folder, raw, pending_local, append_cancel);
            return Source.REMOVE;
        });
        return draft;
    }

    private GenericArray<string> draft_uids_to_purge (string replace_uid) {
        var list = new GenericArray<string> ();
        list.add (replace_uid);
        var server = this.draft_local_to_server.get (replace_uid);
        if (server != null && server != replace_uid)
            list.add (server);
        /* Reverse: replace_uid is already the server UID — drop its local twin. */
        this.draft_local_to_server.foreach ((local, mapped) => {
            if (mapped == replace_uid && local != replace_uid)
                list.add (local);
        });
        return list;
    }

    private void cancel_draft_append (string uid) {
        var c = this.draft_append_cancels.get (uid);
        if (c != null && !c.is_cancelled ())
            c.cancel ();
        this.draft_append_cancels.remove (uid);
        var server = this.draft_local_to_server.get (uid);
        if (server != null) {
            var c2 = this.draft_append_cancels.get (server);
            if (c2 != null && !c2.is_cancelled ())
                c2.cancel ();
            this.draft_append_cancels.remove (server);
        }
    }

    /** Sync, no IMAP — compose must not wait on the network. */
    private Folder resolve_drafts_folder_fast (Account account) {
        var cached = this.folder_list_cache.get (account.uid);
        if (cached != null) {
            for (uint i = 0; i < cached.length; i++) {
                if (cached[i].kind == FolderKind.DRAFTS)
                    return cached[i];
            }
        }
        if (account.kind == AccountKind.GOOGLE) {
            return new Folder () {
                name = C_("Mail folder", "Drafts"),
                full_name = "[Gmail]/Bozze",
                flags = 0,
            };
        }
        return new Folder () {
            name = C_("Mail folder", "Drafts"),
            full_name = "Drafts",
            flags = 0,
        };
    }

    private async void push_draft_append (
        Account account,
        Folder drafts,
        string rfc822,
        string local_uid,
        Cancellable? parent_cancel = null
    ) {
        var timed = new Cancellable ();
        ulong parent_id = 0;
        if (parent_cancel != null) {
            if (parent_cancel.is_cancelled ())
                timed.cancel ();
            else {
                parent_id = parent_cancel.connect (() => {
                    timed.cancel ();
                });
            }
        }
        var timeout_id = Timeout.add_seconds (25, () => {
            if (!timed.is_cancelled ()) {
                Utils.sync_log ("imap Drafts APPEND timeout — cancelling");
                timed.cancel ();
            }
            return Source.REMOVE;
        });
        try {
            string? appended_uid = null;
            string? used_mailbox = null;
            yield run_on_imap_thread (() => {
                Error? last = null;
                string[] candidates = {
                    drafts.full_name,
                    "[Gmail]/Bozze",
                    "[Gmail]/Drafts",
                    "Drafts",
                    "Bozze",
                };
                var tried = new HashTable<string, uint8> (str_hash, str_equal);
                for (uint i = 0; i < candidates.length; i++) {
                    if (timed.is_cancelled ())
                        throw new IOError.CANCELLED ("Draft APPEND cancelled");
                    var mailbox = candidates[i];
                    if (mailbox == null || mailbox.length == 0 || tried.contains (mailbox))
                        continue;
                    tried.set (mailbox, 1);
                    var client = open_client (account, timed);
                    try {
                        appended_uid = client.append_rfc822 (
                            mailbox, rfc822, "\\Draft \\Seen", timed
                        );
                        used_mailbox = mailbox;
                        return;
                    } catch (Error e) {
                        last = e;
                        Utils.sync_log ("imap Drafts APPEND try “%s”: %s".printf (
                            mailbox, e.message
                        ));
                    } finally {
                        client.logout (null);
                    }
                }
                if (last != null)
                    throw last;
                throw new IOError.FAILED (_("Could not APPEND the draft."));
            });

            Utils.sync_log ("imap Drafts APPEND → %s uid=%s (was %s)".printf (
                used_mailbox ?? "?", appended_uid ?? "(none)", local_uid
            ));

            if (timed.is_cancelled ())
                return;
            if (appended_uid == null || appended_uid.length == 0
                || appended_uid == local_uid)
                return;

            this.draft_local_to_server.set (local_uid, appended_uid);

            /* Promote local placeholder to the server UID in the UI. */
            drafts.full_name = used_mailbox ?? drafts.full_name;
            var content = this.local_outgoing_bodies.get (local_uid);
            if (content == null)
                content = content_from_rfc822 (appended_uid, rfc822);
            else
                content.uid = appended_uid;
            this.local_outgoing_bodies.remove (local_uid);
            this.body_ram.set (body_key (account, drafts, appended_uid), content);
            try {
                var file = body_file (account, drafts, appended_uid);
                var parent = file.get_parent ();
                if (parent != null && !parent.query_exists (null))
                    parent.make_directory_with_parents (null);
                file.replace_contents (rfc822.data, null, false, FileCreateFlags.PRIVATE, null, null);
            } catch (Error e) {
                warning ("ImapMailBackend draft body promote: %s", e.message);
            }
            try {
                local_outgoing_body_file (account, local_uid).delete (null);
            } catch (Error e) {
            }

            var promoted = new Message () {
                uid = appended_uid,
                subject = content.subject ?? _("(No subject)"),
                from = content.from ?? "",
                to = content.to ?? "",
                cc = content.cc ?? "",
                list_address = (content.to != null && content.to.length > 0)
                    ? content.to : (content.from ?? ""),
                date = content.date > 0 ? content.date : new DateTime.now_local ().to_unix (),
                seen = true,
                outgoing = true,
                local_only = false,
                preview = content.plain_text,
                folder_name = drafts.name,
                folder_full_name = drafts.full_name,
                has_attachment = false,
            };
            draft_saved (account, promoted, local_uid);
        } catch (Error e) {
            if (!(e is IOError.CANCELLED))
                warning ("ImapMailBackend draft APPEND: %s", e.message);
            Utils.sync_log ("imap Drafts APPEND FAILED: %s".printf (e.message));
        } finally {
            if (timeout_id != 0)
                Source.remove (timeout_id);
            if (parent_cancel != null && parent_id != 0)
                parent_cancel.disconnect (parent_id);
            this.draft_append_cancels.remove (local_uid);
        }
    }

    private async void purge_replaced_draft (
        Account account,
        Folder folder,
        string uid,
        Cancellable? cancellable
    ) throws Error {
        this.local_outgoing_bodies.remove (uid);
        try {
            local_outgoing_body_file (account, uid).delete (null);
        } catch (Error e) {
        }
        try {
            body_file (account, folder, uid).delete (null);
        } catch (Error e) {
        }
        this.body_ram.remove (body_key (account, folder, uid));

        if (uid.has_prefix ("local-draft-") || uid.has_prefix ("local-sent-")) {
            this.draft_local_to_server.remove (uid);
            draft_removed (account, folder, uid);
            return;
        }

        /* Prefer the real Gmail Drafts wire name if the Folder handle is stale. */
        string[] mailboxes = {
            folder.full_name,
            "[Gmail]/Bozze",
            "[Gmail]/Drafts",
            "Drafts",
            "Bozze",
        };
        var uids = new GenericArray<string> ();
        uids.add (uid);
        yield run_on_imap_thread (() => {
            Error? last = null;
            var tried = new HashTable<string, uint8> (str_hash, str_equal);
            for (uint i = 0; i < mailboxes.length; i++) {
                var mailbox = mailboxes[i];
                if (mailbox == null || mailbox.length == 0 || tried.contains (mailbox))
                    continue;
                tried.set (mailbox, 1);
                var client = open_client (account, cancellable);
                try {
                    client.select (mailbox, cancellable);
                    client.uid_store_flags (uids, "\\Deleted", true, cancellable);
                    try {
                        client.expunge (cancellable);
                    } catch (Error e) {
                        warning ("draft purge EXPUNGE: %s", e.message);
                    }
                    last = null;
                    return;
                } catch (Error e) {
                    last = e;
                } finally {
                    client.logout (null);
                }
            }
            if (last != null)
                throw last;
        });
        /* Drop any local→server map entries that pointed here. */
        var drop_locals = new GenericArray<string> ();
        this.draft_local_to_server.foreach ((local, mapped) => {
            if (mapped == uid)
                drop_locals.add (local);
        });
        for (uint i = 0; i < drop_locals.length; i++)
            this.draft_local_to_server.remove (drop_locals[i]);
        draft_removed (account, folder, uid);
    }

    private static string build_outgoing_rfc822 (
        Identity identity,
        string to,
        string? cc,
        string? bcc,
        string subject,
        string body,
        string? html,
        GenericArray<Attachment>? attachments,
        MessageContent? reply_of,
        bool is_forward,
        bool high_priority
    ) {
        var to_list = LetterSmtp.MimeBuilder.parse_address_list (to);
        var cc_list = LetterSmtp.MimeBuilder.parse_address_list (cc);
        var bcc_list = LetterSmtp.MimeBuilder.parse_address_list (bcc);
        string? in_reply = null;
        string? references = null;
        if (reply_of != null && !is_forward) {
            in_reply = angle_msgid (reply_of.message_id);
            references = in_reply;
        } else if (reply_of != null) {
            references = angle_msgid (reply_of.message_id);
        }
        return LetterSmtp.MimeBuilder.build (
            identity.name ?? identity.address,
            identity.address,
            to_list,
            cc_list,
            bcc_list,
            subject,
            body,
            html,
            attachments,
            in_reply,
            references,
            high_priority
        );
    }

    private static Message message_from_outgoing_rfc822 (
        string uid,
        string rfc822,
        Identity identity,
        string to,
        string? cc,
        string subject,
        string body,
        GenericArray<Attachment>? attachments,
        MessageContent? reply_of,
        bool high_priority,
        bool outgoing,
        bool local_only
    ) {
        string hdrs;
        string _body_unused;
        split_headers_body (rfc822, out hdrs, out _body_unused);
        var msgid = angle_msgid (header_value (hdrs, "message-id"));
        var preview = replace_literal_imap ((body ?? "").make_valid ().strip (), "\n", " ");
        if (preview.length > 140)
            preview = preview.substring (0, 140);
        var subj = subject.strip ().length > 0 ? subject.strip () : _("(No subject)");
        var from_disp = (identity.name != null && identity.name.length > 0
            && identity.name != identity.address)
            ? identity.name
            : identity.address;
        var to_disp = to.strip ();
        uint64[] refs = {};
        if (reply_of != null && reply_of.message_id != null && reply_of.message_id.length > 0) {
            var rh = MailSession.hash_message_id_raw (angle_msgid (reply_of.message_id));
            if (rh != 0)
                refs = { rh };
        }
        return new Message () {
            uid = uid,
            subject = subj,
            from = from_disp,
            to = to_disp,
            cc = cc ?? "",
            list_address = to_disp.length > 0 ? to_disp : from_disp,
            date = new DateTime.now_local ().to_unix (),
            seen = true,
            outgoing = outgoing,
            local_only = local_only,
            preview = preview.length > 0 ? preview : null,
            has_attachment = attachments != null && attachments.length > 0,
            important = high_priority,
            msgid_hash = MailSession.hash_message_id_raw (msgid),
            msgid_refs = refs,
        };
    }

    public async void reset_account_storage (Account account) throws Error {
        this.body_ram.remove_all ();
        var id = account.source_uid ?? account.uid;
        if (id != null && id.length > 0)
            IdentityCatalog.wipe_local_library_files (id);
    }

    private LetterImap.Client open_client (Account account, Cancellable? cancellable) throws Error {
        /* Catalog / libsecret / Soup token refresh are not safe across the
         * IDLE worker + main-thread align. One connect at a time. */
        this.imap_io_lock.lock ();
        try {
            return open_client_unlocked (account, cancellable);
        } finally {
            this.imap_io_lock.unlock ();
        }
    }

    private LetterImap.Client open_client_unlocked (Account account, Cancellable? cancellable) throws Error {
        var id_acc = find_identity_unlocked (account);
        if (id_acc == null) {
            throw new IOError.NOT_FOUND (
                _("No Identity account for “%s”.").printf (account.email ?? account.uid)
            );
        }
        var host = id_acc.imap_host;
        uint16 port = (uint16) id_acc.imap_port;
        if (port == 0)
            port = 993;
        var user = id_acc.username ?? id_acc.email;

        var client = new LetterImap.Client ();
        client.connect_tls (host, port, cancellable);
        if (id_acc.uses_oauth2 ()) {
            var access = IdentityOAuth.ensure_access_token_sync (id_acc);
            try {
                client.authenticate_xoauth2 (user, access, cancellable);
            } catch (Error auth_err) {
                /* Access still “fresh” in libsecret but rejected (audience /
                 * revocation). Force one refresh then retry on a new socket. */
                if (!(auth_err is LetterImap.Error.AUTH))
                    throw auth_err;
                Utils.sync_log (
                    "XOAUTH2 rejected for “%s” — refreshing token".printf (id_acc.email)
                );
                IdentityOAuth.force_refresh_access_token_sync (id_acc);
                access = IdentityOAuth.ensure_access_token_sync (id_acc);
                try {
                    client.logout (null);
                } catch (Error e) {
                }
                client = new LetterImap.Client ();
                client.connect_tls (host, port, cancellable);
                client.authenticate_xoauth2 (user, access, cancellable);
            }
        } else {
            var password = IdentitySecrets.lookup_password (id_acc.id);
            if (password == null || password.length == 0) {
                throw new IOError.NOT_FOUND (
                    _("No password in libsecret for “%s”.").printf (id_acc.email)
                );
            }
            client.login (user, password, cancellable);
            Secret.password_wipe (password);
        }
        return client;
    }

    private IdentityAccount? find_identity (Account account) {
        this.imap_io_lock.lock ();
        try {
            return find_identity_unlocked (account);
        } finally {
            this.imap_io_lock.unlock ();
        }
    }

    private IdentityAccount? find_identity_unlocked (Account account) {
        /* Prefer the in-memory catalog; reload only when empty. */
        if (this.catalog.accounts.length == 0) {
            try {
                this.catalog = IdentityCatalog.load ();
            } catch (Error e) {
                warning ("ImapMailBackend reload catalog: %s", e.message);
            }
        }
        for (uint i = 0; i < this.catalog.accounts.length; i++) {
            var a = this.catalog.accounts[i];
            if (a.id == account.uid)
                return a;
            if (account.email != null && a.email != null
                && a.email.down () == account.email.down ())
                return a;
        }
        /* Stale cache — one forced reload. */
        try {
            this.catalog = IdentityCatalog.load ();
        } catch (Error e) {
            warning ("ImapMailBackend reload catalog: %s", e.message);
            return null;
        }
        for (uint i = 0; i < this.catalog.accounts.length; i++) {
            var a = this.catalog.accounts[i];
            if (a.id == account.uid)
                return a;
            if (account.email != null && a.email != null
                && a.email.down () == account.email.down ())
                return a;
        }
        return null;
    }

    private static File local_outgoing_body_file (Account account, string uid) {
        var dir = Path.build_filename (
            Environment.get_user_data_dir (),
            "letter",
            "engine",
            "imap",
            account.source_uid ?? account.uid,
            "outgoing"
        );
        return File.new_for_path (Path.build_filename (dir, uid));
    }

    private static string body_key (Account account, Folder folder, string uid) {
        return "%s\n%s\n%s".printf (account.uid, folder.full_name, uid);
    }

    private static File body_file (Account account, Folder folder, string uid) {
        var safe_folder = folder.full_name.replace ("/", "_").replace (" ", "_");
        var path = Path.build_filename (
            Environment.get_user_data_dir (),
            "letter",
            "engine",
            "imap",
            account.uid,
            safe_folder,
            uid + ".eml"
        );
        return File.new_for_path (path);
    }

    private static bool query_has_text_clause (SearchQuery query) {
        for (uint i = 0; i < query.clauses.length; i++) {
            var clause = query.clauses[i];
            if (clause.kind == SearchFilterKind.TEXT && clause.folded.length > 0)
                return true;
        }
        return false;
    }

    private GenericArray<string> search_body_index (
        Account account,
        Folder folder,
        SearchQuery query,
        uint limit
    ) {
        var uids = new GenericArray<string> ();
        var tokens = query.text_tokens ();
        if (tokens.length == 0)
            return uids;

        var t0 = Utils.sync_tick ();
        uint scanned = 0;
        BodyTextIndex.scan (account.source_uid ?? account.uid, folder.full_name, (uid, text) => {
            scanned++;
            if (query.match_any) {
                var any = false;
                for (uint i = 0; i < tokens.length; i++) {
                    if (text.contains (tokens[i])) {
                        any = true;
                        break;
                    }
                }
                if (!any)
                    return true;
            } else {
                for (uint i = 0; i < tokens.length; i++) {
                    if (!text.contains (tokens[i]))
                        return true;
                }
            }
            uids.add (uid);
            return uids.length < limit;
        });

        if (scanned > 0) {
            Utils.sync_log (
                "imap body index search “%s” %s → %u of %u indexed".printf (
                    folder.name,
                    Utils.sync_ms (t0),
                    uids.length,
                    scanned
                )
            );
        }
        return uids;
    }

    private void index_body_content (
        Account account,
        Folder folder,
        string uid,
        MessageContent content
    ) {
        this.body_text_index.add (
            account.source_uid ?? account.uid,
            folder.full_name,
            uid,
            searchable_plain (content)
        );
    }

    private bool index_body_file_if_needed (
        Account account,
        Folder folder,
        string uid
    ) {
        var account_uid = account.source_uid ?? account.uid;
        if (this.body_text_index.has (account_uid, folder.full_name, uid))
            return false;
        var file = body_file (account, folder, uid);
        if (!file.query_exists (null))
            return false;
        try {
            uint8[] data;
            string etag;
            file.load_contents (null, out data, out etag);
            var content = content_from_rfc822 (uid, (string) data);
            index_body_content (account, folder, uid, content);
            return this.body_text_index.has (account_uid, folder.full_name, uid);
        } catch (Error e) {
            debug ("ImapMailBackend index file %s: %s", uid, e.message);
            return false;
        }
    }

    /* Prefer text/plain; fall back to a rough HTML strip so HTML-only mail
     * still lands in BodyTextIndex.
     * Never use Vala string.replace() on MIME text — it builds a GRegex and
     * assert_not_reached()'s on invalid UTF-8 (common in real mail). */
    private static string? searchable_plain (MessageContent content) {
        if (content.plain_text != null && content.plain_text.strip ().length > 0)
            return content.plain_text.make_valid ();
        if (content.html == null || content.html.strip ().length == 0)
            return null;
        var text = content.html.make_valid ();
        try {
            var re = new Regex ("<[^>]+>", RegexCompileFlags.OPTIMIZE);
            text = re.replace (text, text.length, 0, "");
        } catch (Error e) {
            /* Keep tagged text rather than abort indexing. */
        }
        text = replace_literal_imap (text, "&nbsp;", " ");
        text = replace_literal_imap (text, "&amp;", "&");
        text = replace_literal_imap (text, "&lt;", "<");
        text = replace_literal_imap (text, "&gt;", ">");
        text = replace_literal_imap (text, "&quot;", "\"");
        text = text.strip ();
        return text.length > 0 ? text : null;
    }

    private static File body_dir (Account account, Folder folder) {
        var safe_folder = folder.full_name.replace ("/", "_").replace (" ", "_");
        return File.new_for_path (Path.build_filename (
            Environment.get_user_data_dir (),
            "letter",
            "engine",
            "imap",
            account.uid,
            safe_folder
        ));
    }

    private void drop_body_files (Account account, Folder folder, string uid) {
        this.body_ram.remove (body_key (account, folder, uid));
        this.local_outgoing_bodies.remove (uid);
        try {
            body_file (account, folder, uid).delete (null);
        } catch (Error e) {
        }
        try {
            local_outgoing_body_file (account, uid).delete (null);
        } catch (Error e) {
        }
    }

    /** After a finished header walk: delete .eml whose UID is no longer listed. */
    private void prune_orphan_bodies (
        Account account,
        Folder folder,
        GenericArray<Message> listed
    ) {
        var dir = body_dir (account, folder);
        if (!dir.query_exists (null))
            return;

        var keep = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < listed.length; i++) {
            var uid = listed[i].uid;
            if (uid != null && uid.length > 0)
                keep.set (uid, 1);
        }

        uint removed = 0;
        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME,
                FileQueryInfoFlags.NONE,
                null
            );
            FileInfo? info;
            while ((info = enumerator.next_file (null)) != null) {
                var name = info.get_name ();
                if (name == null || !name.has_suffix (".eml"))
                    continue;
                var uid = name.substring (0, name.length - 4);
                if (keep.contains (uid))
                    continue;
                try {
                    dir.get_child (name).delete (null);
                    this.body_ram.remove (body_key (account, folder, uid));
                    removed++;
                } catch (Error e) {
                }
            }
        } catch (Error e) {
            warning ("ImapMailBackend prune bodies “%s”: %s", folder.name, e.message);
            return;
        }
        if (removed > 0) {
            Utils.sync_log (
                "imap prune “%s” removed %u orphan body file(s) (keep %u)".printf (
                    folder.name,
                    removed,
                    keep.size ()
                )
            );
        }
    }

    private uint wipe_folder_body_dir (Account account, Folder folder) {
        var dir = body_dir (account, folder);
        if (!dir.query_exists (null))
            return 0;
        uint removed = 0;
        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME,
                FileQueryInfoFlags.NONE,
                null
            );
            FileInfo? info;
            while ((info = enumerator.next_file (null)) != null) {
                var name = info.get_name ();
                if (name == null)
                    continue;
                try {
                    dir.get_child (name).delete (null);
                    if (name.has_suffix (".eml")) {
                        var uid = name.substring (0, name.length - 4);
                        this.body_ram.remove (body_key (account, folder, uid));
                    }
                    removed++;
                } catch (Error e) {
                }
            }
        } catch (Error e) {
            warning ("ImapMailBackend wipe bodies “%s”: %s", folder.name, e.message);
        }
        return removed;
    }

    private static Error not_supported (string what) {
        return new IOError.NOT_SUPPORTED (
            _("IMAP engine does not support %s yet (slice 1).").printf (what)
        );
    }

    private static string folder_key (Account account, Folder folder) {
        return "%s\n%s".printf (account.uid, folder.full_name);
    }

    private static string watch_key (Account account, Folder folder) {
        return "%s\n%s".printf (account.source_uid ?? account.uid, folder.full_name);
    }

    private void stop_idle_watch (string key) {
        IdleWatch? watch = null;
        this.idle_state_lock.lock ();
        try {
            watch = this.idle_watches.get (key);
            if (watch == null)
                return;
            this.idle_watches.remove (key);
            watch.thread_running = false;
        } finally {
            this.idle_state_lock.unlock ();
        }
        if (watch != null && !watch.cancellable.is_cancelled ())
            watch.cancellable.cancel ();
    }

    private void set_folder_exists_safe (string key, int exists) {
        this.idle_state_lock.lock ();
        try {
            this.folder_exists.set (key, exists);
        } finally {
            this.idle_state_lock.unlock ();
        }
    }

    private void emit_folder_changed_idle (string account_key, string folder_name) {
        var acc = account_key;
        var fold = folder_name;
        Idle.add (() => {
            folder_changed (acc, fold);
            return Source.REMOVE;
        });
    }

    private void rebuild_seq_uids (IdleWatch watch, LetterImap.Client client) throws Error {
        if (watch.last_exists == 0) {
            watch.seq_uids = new GenericArray<string> ();
            return;
        }
        watch.seq_uids = client.fetch_uid_range (1, watch.last_exists, watch.cancellable);
    }

    private static string? resolve_idle_uid (IdleWatch watch, uint seq, string? fetch_uid) {
        if (fetch_uid != null && fetch_uid.length > 0) {
            if (seq >= 1 && seq <= watch.seq_uids.length)
                watch.seq_uids[(int) (seq - 1)] = fetch_uid;
            return fetch_uid;
        }
        if (seq >= 1 && seq <= watch.seq_uids.length) {
            var uid = watch.seq_uids[(int) (seq - 1)];
            if (uid != null && uid.length > 0)
                return uid;
        }
        return null;
    }

    private void queue_pending_flags (IdleWatch watch, string uid, bool seen, bool flagged) {
        this.idle_state_lock.lock ();
        try {
            watch.pending_flags.set (uid, new PendingFlagUpdate () {
                seen = seen,
                flagged = flagged
            });
        } finally {
            this.idle_state_lock.unlock ();
        }
    }

    private void queue_pending_removed (IdleWatch watch, string uid) {
        this.idle_state_lock.lock ();
        try {
            watch.pending_flags.remove (uid);
            for (uint i = 0; i < watch.pending_headers.length; ) {
                if (watch.pending_headers[i].uid == uid)
                    watch.pending_headers.remove_index (i);
                else
                    i++;
            }
            watch.pending_removed.add (uid);
        } finally {
            this.idle_state_lock.unlock ();
        }
    }

    private void idle_loop (IdleWatch watch, string account_key, string folder_name) {
        LetterImap.Client? client = null;
        var folder_stub = new Folder () {
            name = watch.folder_name,
            full_name = watch.folder_full_name
        };
        try {
            client = open_client (watch.account, watch.cancellable);
            var exists = client.select (watch.folder_full_name, watch.cancellable);
            watch.last_exists = exists;
            set_folder_exists_safe (watch.folder_key, (int) exists);
            try {
                rebuild_seq_uids (watch, client);
            } catch (Error e) {
                Utils.sync_log (
                    "IDLE “%s” UID map failed: %s".printf (watch.folder_name, e.message)
                );
                watch.seq_uids = new GenericArray<string> ();
            }

            while (watch.thread_running && !watch.cancellable.is_cancelled ()) {
                LetterImap.Client.IdleBatch batch;
                try {
                    batch = client.idle (IDLE_RENEW_SECONDS, watch.cancellable);
                } catch (Error e) {
                    if (watch.cancellable.is_cancelled ())
                        break;
                    Utils.sync_log (
                        "IDLE “%s” error: %s — reconnecting".printf (watch.folder_name, e.message)
                    );
                    try {
                        client.logout (null);
                    } catch (Error e2) {
                    }
                    client = open_client (watch.account, watch.cancellable);
                    exists = client.select (watch.folder_full_name, watch.cancellable);
                    watch.last_exists = exists;
                    set_folder_exists_safe (watch.folder_key, (int) exists);
                    try {
                        rebuild_seq_uids (watch, client);
                    } catch (Error e3) {
                        watch.seq_uids = new GenericArray<string> ();
                    }
                    continue;
                }

                if (batch.wake == LetterImap.Client.IdleWake.CANCELLED)
                    break;
                if (batch.wake == LetterImap.Client.IdleWake.TIMEOUT && batch.events.length == 0)
                    continue; /* renew IDLE */

                var dirty = false;
                uint latest_exists = batch.has_exists ? batch.exists_hint : 0;
                for (uint i = 0; i < batch.events.length; i++) {
                    var ev = batch.events[i];
                    if (ev.wake == LetterImap.Client.IdleWake.FLAGS && ev.flags_present) {
                        var uid = resolve_idle_uid (watch, ev.fetch_seq, ev.fetch_uid);
                        if (uid == null)
                            continue;
                        queue_pending_flags (watch, uid, ev.seen, ev.flagged);
                        Utils.sync_log (
                            "IDLE “%s” FLAGS uid %s seen=%s flagged=%s".printf (
                                watch.folder_name,
                                uid,
                                ev.seen ? "1" : "0",
                                ev.flagged ? "1" : "0"
                            )
                        );
                        dirty = true;
                        continue;
                    }

                    if (ev.wake == LetterImap.Client.IdleWake.EXPUNGE) {
                        var seq = ev.expunge_seq;
                        string? uid = null;
                        if (seq >= 1 && seq <= watch.seq_uids.length) {
                            uid = watch.seq_uids[(int) (seq - 1)];
                            watch.seq_uids.remove_index (seq - 1);
                        }
                        if (watch.last_exists > 0)
                            watch.last_exists--;
                        set_folder_exists_safe (watch.folder_key, (int) watch.last_exists);
                        if (uid != null && uid.length > 0) {
                            queue_pending_removed (watch, uid);
                            Utils.sync_log (
                                "IDLE “%s” EXPUNGE uid %s (seq %u, exists %u)".printf (
                                    watch.folder_name,
                                    uid,
                                    seq,
                                    watch.last_exists
                                )
                            );
                            dirty = true;
                        }
                        continue;
                    }

                    if (ev.wake == LetterImap.Client.IdleWake.EXISTS)
                        latest_exists = ev.exists_hint;
                }

                if (batch.has_exists || latest_exists > 0) {
                    var exists_hint = batch.has_exists ? batch.exists_hint : latest_exists;
                    if (exists_hint > watch.last_exists) {
                        var from_seq = watch.last_exists + 1;
                        var to_seq = exists_hint;
                        var listed = new GenericArray<Message> ();
                        try {
                            var more = client.fetch_uid_range (from_seq, to_seq, watch.cancellable);
                            for (uint j = 0; j < more.length; j++)
                                watch.seq_uids.add (more[j]);
                            append_header_range (
                                client,
                                folder_stub,
                                from_seq,
                                to_seq,
                                listed,
                                watch.cancellable
                            );
                            watch.last_exists = exists_hint;
                            set_folder_exists_safe (watch.folder_key, (int) exists_hint);
                        } catch (Error e) {
                            Utils.sync_log (
                                "IDLE FETCH “%s” failed: %s".printf (watch.folder_name, e.message)
                            );
                        }
                        if (listed.length > 0) {
                            this.idle_state_lock.lock ();
                            try {
                                for (uint j = 0; j < listed.length; j++)
                                    watch.pending_headers.add (listed[j]);
                            } finally {
                                this.idle_state_lock.unlock ();
                            }
                            Utils.sync_log (
                                "IDLE “%s” +%u header(s) (exists %u)".printf (
                                    watch.folder_name,
                                    listed.length,
                                    exists_hint
                                )
                            );
                            dirty = true;
                        }
                    } else if (exists_hint < watch.last_exists) {
                        /* Shrink without matching EXPUNGEs — rebuild map. */
                        watch.last_exists = exists_hint;
                        set_folder_exists_safe (watch.folder_key, (int) exists_hint);
                        try {
                            rebuild_seq_uids (watch, client);
                        } catch (Error e) {
                            watch.seq_uids = new GenericArray<string> ();
                        }
                        dirty = true;
                    } else {
                        /* EXISTS matches after EXPUNGEs — keep last_exists in sync. */
                        set_folder_exists_safe (watch.folder_key, (int) watch.last_exists);
                    }
                }

                if (dirty)
                    emit_folder_changed_idle (account_key, folder_name);
            }
        } catch (Error e) {
            if (!(e is IOError.CANCELLED) && !watch.cancellable.is_cancelled ()) {
                Utils.sync_log ("IDLE watch “%s” stopped: %s".printf (watch.folder_name, e.message));
            }
        } finally {
            watch.thread_running = false;
            try {
                client?.logout (null);
            } catch (Error e) {
            }
            this.idle_state_lock.lock ();
            try {
                var cur = this.idle_watches.get (watch.watch_key);
                if (cur == watch)
                    this.idle_watches.remove (watch.watch_key);
            } finally {
                this.idle_state_lock.unlock ();
            }
        }
    }

    /** Newest tip UIDs overlay prior Letter headers (flags refresh + new heads). */
    private static GenericArray<Message> merge_tip_into_previous (
        GenericArray<Message> previous,
        GenericArray<Message> tip
    ) {
        var by_uid = new HashTable<string, Message> (str_hash, str_equal);
        var merged = new GenericArray<Message> ();
        for (uint i = 0; i < tip.length; i++) {
            var message = tip[i];
            if (message.uid == null || message.uid.length == 0)
                continue;
            /* Keep a prior paperclip if this tip FETCH missed Content-Type. */
            for (uint p = 0; p < previous.length; p++) {
                if (previous[p].uid != message.uid)
                    continue;
                if (previous[p].has_attachment)
                    message.has_attachment = true;
                break;
            }
            by_uid.set (message.uid, message);
            merged.add (message);
        }
        for (uint i = 0; i < previous.length; i++) {
            var message = previous[i];
            if (message.uid == null || message.uid.length == 0)
                continue;
            if (by_uid.contains (message.uid))
                continue;
            merged.add (message);
        }
        sort_by_date_desc (merged);
        return merged;
    }

    private static GenericArray<Message> retain_local_placeholders (
        GenericArray<Message> live,
        GenericArray<Message>? previous
    ) {
        if (previous == null || previous.length == 0)
            return live;

        var have_uid = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < live.length; i++) {
            have_uid.set (live[i].uid, 1);
            live[i].local_only = false;
        }

        var added = false;
        for (uint i = 0; i < previous.length; i++) {
            var message = previous[i];
            if (!message.is_placeholder)
                continue;
            if (have_uid.contains (message.uid))
                continue;
            if (message.msgid_hash != 0 && live_has_msgid (live, message.msgid_hash))
                continue;
            if (live_has_outgoing_send (live, message))
                continue;
            live.add (message);
            added = true;
        }
        if (!added)
            return live;
        sort_by_date_desc (live);
        return live;
    }

    private static bool live_has_outgoing_send (GenericArray<Message> live, Message candidate) {
        for (uint i = 0; i < live.length; i++) {
            if (Conversation.same_outgoing_send (live[i], candidate))
                return true;
        }
        return false;
    }

    private static bool live_has_msgid (GenericArray<Message> live, uint64 hash) {
        for (uint i = 0; i < live.length; i++) {
            if (live[i].msgid_hash == hash)
                return true;
        }
        return false;
    }

    private static void sort_by_date_desc (GenericArray<Message> messages) {
        messages.sort ((a, b) => {
            if (a.date < b.date)
                return 1;
            if (a.date > b.date)
                return -1;
            return strcmp (b.uid ?? "", a.uid ?? "");
        });
    }

    /* "Name" <a@b> / Name <a@b> → Name; bare address unchanged. */
    private static string format_from_display (string raw) {
        var s = raw.strip ();
        if (s.length == 0)
            return raw;
        var lt = s.index_of_char ('<');
        var gt = s.last_index_of_char ('>');
        if (lt > 0 && gt > lt) {
            var name = s.substring (0, lt).strip ();
            if (name.has_prefix ("\"") && name.has_suffix ("\"") && name.length >= 2)
                name = name.substring (1, name.length - 2).strip ();
            if (name.length > 0)
                return name;
            return s.substring (lt + 1, gt - lt - 1).strip ();
        }
        if (lt == 0 && gt > lt)
            return s.substring (1, gt - 1).strip ();
        return s;
    }

    /**
     * RFC 2822 / 5322 Date (`Mon, 12 Oct 2026 08:36:38 +0000`) and Java/asctime
     * (`Thu Sep 08 10:27:43 CEST 2016`) used by older Findomestic / servlet mail.
     */
    private static int64 parse_mail_date (string? raw) {
        if (raw == null || raw.length == 0)
            return 0;

        try {
            var iso = new DateTime.from_iso8601 (raw, null);
            if (iso != null)
                return iso.to_unix ();
        } catch (Error e) {
        }

        var s = strip_mail_date_comments (raw.strip ());
        /* Drop optional day-of-week when comma-form (RFC). */
        var comma = s.index_of_char (',');
        if (comma >= 0 && comma < 4)
            s = s.substring (comma + 1).strip ();

        var parts = s.split_set (" \t");
        var tokens = new GenericArray<string> ();
        for (uint i = 0; i < parts.length; i++) {
            if (parts[i].length > 0)
                tokens.add (parts[i]);
        }
        if (tokens.length < 4)
            return 0;

        int day;
        int month;
        int year;
        string time_tok;
        string? tz_tok = null;

        /* asctime: Thu Sep 08 10:27:43 CEST 2016  (no comma after weekday) */
        if (mail_month_number (tokens[0]) == 0
            && tokens.length >= 5
            && mail_month_number (tokens[1]) > 0) {
            month = mail_month_number (tokens[1]);
            day = int.parse (tokens[2]);
            time_tok = tokens[3];
            if (tokens.length >= 6) {
                tz_tok = tokens[4];
                year = int.parse (tokens[5]);
            } else {
                year = int.parse (tokens[4]);
            }
        } else {
            /* RFC: 08 Sep 2016 10:27:43 +0200 */
            day = int.parse (tokens[0]);
            month = mail_month_number (tokens[1]);
            year = int.parse (tokens[2]);
            time_tok = tokens[3];
            if (tokens.length >= 5)
                tz_tok = tokens[4];
        }

        if (day <= 0 || month <= 0 || year <= 0)
            return 0;
        if (year < 100)
            year += year >= 70 ? 1900 : 2000;

        int hour = 0;
        int minute = 0;
        int second = 0;
        var time_bits = time_tok.split (":");
        if (time_bits.length >= 2) {
            hour = int.parse (time_bits[0]);
            minute = int.parse (time_bits[1]);
            if (time_bits.length >= 3)
                second = int.parse (time_bits[2]);
        }

        int tz_offset_minutes = tz_tok != null ? mail_tz_offset_minutes (tz_tok) : 0;
        var tz = new TimeZone.offset (tz_offset_minutes * 60);
        var dt = new DateTime (tz, year, month, day, hour, minute, (double) second);
        if (dt == null)
            return 0;
        return dt.to_unix ();
    }

    /** IMAP INTERNALDATE: `08-Sep-2016 08:27:44 +0000`. */
    private static int64 parse_imap_internaldate (string? raw) {
        if (raw == null || raw.length == 0)
            return 0;
        var parts = raw.strip ().split_set (" \t");
        var tokens = new GenericArray<string> ();
        for (uint i = 0; i < parts.length; i++) {
            if (parts[i].length > 0)
                tokens.add (parts[i]);
        }
        if (tokens.length < 2)
            return 0;
        var dmy = tokens[0].split ("-");
        if (dmy.length != 3)
            return 0;
        int day = int.parse (dmy[0]);
        int month = mail_month_number (dmy[1]);
        int year = int.parse (dmy[2]);
        if (day <= 0 || month <= 0 || year <= 0)
            return 0;

        int hour = 0;
        int minute = 0;
        int second = 0;
        var time_bits = tokens[1].split (":");
        if (time_bits.length >= 2) {
            hour = int.parse (time_bits[0]);
            minute = int.parse (time_bits[1]);
            if (time_bits.length >= 3)
                second = int.parse (time_bits[2]);
        }
        int tz_offset_minutes = tokens.length >= 3
            ? mail_tz_offset_minutes (tokens[2])
            : 0;
        var tz = new TimeZone.offset (tz_offset_minutes * 60);
        var dt = new DateTime (tz, year, month, day, hour, minute, (double) second);
        if (dt == null)
            return 0;
        return dt.to_unix ();
    }

    private static string strip_mail_date_comments (string s) {
        var out = new StringBuilder ();
        int depth = 0;
        for (int i = 0; i < s.length; i++) {
            var c = s[i];
            if (c == '(') {
                depth++;
                continue;
            }
            if (c == ')' && depth > 0) {
                depth--;
                continue;
            }
            if (depth == 0)
                out.append_c (c);
        }
        return out.str.strip ();
    }

    private static int mail_month_number (string mon) {
        switch (mon.down ().substring (0, int.min (3, mon.length))) {
            case "jan": return 1;
            case "feb": return 2;
            case "mar": return 3;
            case "apr": return 4;
            case "may": return 5;
            case "jun": return 6;
            case "jul": return 7;
            case "aug": return 8;
            case "sep": return 9;
            case "oct": return 10;
            case "nov": return 11;
            case "dec": return 12;
            default: return 0;
        }
    }

    private static int mail_tz_offset_minutes (string tz) {
        var t = tz.strip ();
        var named = t.up ();
        switch (named) {
            case "UT":
            case "UTC":
            case "GMT":
            case "Z":
            case "WET":
                return 0;
            case "CET":
            case "MET":
            case "BST":
            case "WEST":
                return 60;
            case "CEST":
            case "MEST":
            case "EET":
                return 120;
            case "EEST":
                return 180;
            case "EDT":
                return -240;
            case "EST":
            case "CDT":
                return -300;
            case "CST":
            case "MDT":
                return -360;
            case "MST":
            case "PDT":
                return -420;
            case "PST":
                return -480;
            default:
                break;
        }
        if (t.length < 4)
            return 0;
        int sign = 1;
        int start = 0;
        if (t[0] == '+') {
            start = 1;
        } else if (t[0] == '-') {
            sign = -1;
            start = 1;
        } else {
            return 0;
        }
        var digits = t.substring (start).replace (":", "");
        if (digits.length < 4)
            return 0;
        int hh = int.parse (digits.substring (0, 2));
        int mm = int.parse (digits.substring (2, 2));
        return sign * (hh * 60 + mm);
    }

    /**
     * RFC 2047 encoded-words in Subject/From/To (`=?utf-8?Q?...?=` / `?B?`).
     * Returns null if input is null; otherwise decoded text (or original on failure).
     */
    private static string? decode_rfc2047 (string? raw) {
        if (raw == null)
            return null;
        if (!raw.contains ("=?"))
            return raw;

        var sb = new StringBuilder ();
        int i = 0;
        while (i < raw.length) {
            var start = raw.index_of ("=?", i);
            if (start < 0) {
                sb.append (raw.substring (i));
                break;
            }
            if (start > i)
                sb.append (raw.substring (i, start - i));

            var charset_end = raw.index_of_char ('?', start + 2);
            if (charset_end < 0) {
                sb.append (raw.substring (start));
                break;
            }
            var enc_end = raw.index_of_char ('?', charset_end + 1);
            if (enc_end < 0 || enc_end + 1 >= raw.length) {
                sb.append (raw.substring (start));
                break;
            }
            var data_end = raw.index_of ("?=", enc_end + 1);
            if (data_end < 0) {
                sb.append (raw.substring (start));
                break;
            }

            var charset = raw.substring (start + 2, charset_end - (start + 2));
            var encoding = raw.substring (charset_end + 1, enc_end - (charset_end + 1)).up ();
            var data = raw.substring (enc_end + 1, data_end - (enc_end + 1));
            var decoded = decode_rfc2047_word (charset, encoding, data);
            sb.append (decoded ?? raw.substring (start, data_end + 2 - start));
            i = data_end + 2;

            /* RFC 2047: linear whitespace between adjacent encoded-words is ignored. */
            var ws = i;
            while (ws < raw.length
                && (raw[ws] == ' ' || raw[ws] == '\t' || raw[ws] == '\r' || raw[ws] == '\n'))
                ws++;
            if (ws > i && ws + 1 < raw.length && raw[ws] == '=' && raw[ws + 1] == '?')
                i = ws;
        }
        return sb.str;
    }

    private static string? decode_rfc2047_word (string charset, string encoding, string data) {
        uint8[] bytes;
        if (encoding == "B") {
            var cleaned = replace_literal_imap (
                replace_literal_imap (replace_literal_imap (data, "\r", ""), "\n", ""),
                " ",
                ""
            );
            try {
                bytes = Base64.decode (cleaned);
            } catch (Error e) {
                return null;
            }
        } else if (encoding == "Q") {
            var ba = new ByteArray ();
            for (int i = 0; i < data.length; i++) {
                if (data[i] == '_') {
                    ba.append ({ ' ' });
                } else if (data[i] == '=' && i + 2 < data.length) {
                    int hi = hex_val (data[i + 1]);
                    int lo = hex_val (data[i + 2]);
                    if (hi >= 0 && lo >= 0) {
                        ba.append ({ (uint8) ((hi << 4) | lo) });
                        i += 2;
                    } else {
                        ba.append ({ data[i] });
                    }
                } else {
                    ba.append ({ data[i] });
                }
            }
            bytes = ba.data[0:ba.len];
        } else {
            return null;
        }

        /* g_convert asserts str != NULL — empty uint8[] is often a NULL pointer. */
        if (bytes == null || bytes.length == 0)
            return "";
        var cs = normalize_charset (charset);
        try {
            return convert ((string) bytes, bytes.length, "UTF-8", cs);
        } catch (ConvertError e) {
            try {
                return convert ((string) bytes, bytes.length, "UTF-8", "UTF-8");
            } catch (ConvertError e2) {
                return data;
            }
        }
    }

    /**
     * RFC822 → MessageContent: text parts, file attachments, and cid: images
     * (multipart/mixed|related|alternative). Mirrors Camel collect_* enough
     * for the reader chips and letterimg: inline rewrite.
     */
    private static MessageContent content_from_rfc822 (string uid, string raw) {
        string headers;
        string body;
        split_headers_body (raw, out headers, out body);

        var subject = decode_rfc2047 (header_value (headers, "subject")) ?? _("(No subject)");
        var from_raw = decode_rfc2047 (header_value (headers, "from")) ?? _("Unknown sender");
        var from = format_from_display (from_raw);
        /* Display name alone has no @ — trust-sender / remote images need this. */
        var from_email = Utils.email_from_header (from_raw);
        var to = decode_rfc2047 (header_value (headers, "to")) ?? "";
        var cc = decode_rfc2047 (header_value (headers, "cc"));
        var date = parse_mail_date (header_value (headers, "date"));

        string? plain = null;
        string? html = null;
        var attachments = new GenericArray<Attachment> ();
        var images = new GenericArray<InlineImage> ();
        walk_mime_tree (headers, body, ref plain, ref html, attachments, images, 0);

        uint64 inline_token = 0;
        string display_html;
        bool rich = false;
        if (html != null && html.strip ().length > 0) {
            if (images.length > 0) {
                inline_token = InlineImagePages.reserve ();
                display_html = rewrite_cid_refs (html, images, inline_token);
            } else {
                display_html = html;
            }
            rich = true;
        } else if (plain != null && plain.strip ().length > 0) {
            display_html = MessageContent.text_to_html (plain);
        } else {
            display_html = MessageContent.text_to_html (
                _("This message has no readable content.")
            );
        }

        var content = new MessageContent () {
            uid = uid,
            subject = subject,
            from = from,
            from_email = from_email,
            to = to,
            cc = cc,
            to_recipients = new GenericArray<Recipient> (),
            cc_recipients = new GenericArray<Recipient> (),
            bcc_recipients = new GenericArray<Recipient> (),
            date = date,
            html = display_html,
            plain_text = plain,
            rich_html = rich,
            inline_token = inline_token,
            inline_images = images.length > 0 ? images : null,
            has_remote_images = Utils.html_has_remote_images (display_html),
            attachments = attachments,
            message_id = header_value (headers, "message-id"),
            in_reply_to = header_value (headers, "in-reply-to"),
            references = header_value (headers, "references"),
        };
        if (inline_token != 0)
            InlineImagePages.publish (content);
        return content;
    }

    private static void split_headers_body (string raw, out string headers, out string body) {
        var idx = raw.index_of ("\r\n\r\n");
        var sep_len = 4;
        if (idx < 0) {
            idx = raw.index_of ("\n\n");
            sep_len = 2;
        }
        if (idx < 0) {
            headers = raw;
            body = "";
            return;
        }
        headers = raw.substring (0, idx);
        body = raw.substring (idx + sep_len);
    }

    private static string? header_value (string headers, string name) {
        string? current = null;
        var value = new StringBuilder ();
        var want = name.down ();

        foreach (var line in headers.split ("\n")) {
            var trimmed = line.has_suffix ("\r") ? line.substring (0, line.length - 1) : line;
            if (trimmed.length > 0 && (trimmed[0] == ' ' || trimmed[0] == '\t')) {
                if (current != null) {
                    value.append_c (' ');
                    value.append (trimmed.strip ());
                }
                continue;
            }
            if (current != null && current == want)
                return value.str;
            value.truncate ();
            current = null;
            var colon = trimmed.index_of_char (':');
            if (colon <= 0)
                continue;
            current = trimmed.substring (0, colon).strip ().down ();
            value.append (trimmed.substring (colon + 1).strip ());
        }
        if (current != null && current == want)
            return value.str;
        return null;
    }

    private static void walk_mime_tree (
        string headers,
        string body,
        ref string? plain,
        ref string? html,
        GenericArray<Attachment> attachments,
        GenericArray<InlineImage> images,
        int depth
    ) {
        if (depth > 24)
            return;

        var ct = header_value (headers, "content-type") ?? "text/plain";
        var ct_down = ct.down ();
        var mime_type = mime_type_only (ct);

        if (ct_down.contains ("multipart/")) {
            var boundary = mime_param (ct, "boundary");
            if (boundary == null || boundary.length == 0) {
                if (plain == null)
                    plain = body;
                return;
            }
            var parts = split_mime_parts (body, boundary);
            for (uint i = 0; i < parts.length; i++) {
                string ph;
                string pb;
                split_headers_body (parts[i], out ph, out pb);
                if (ph.strip ().length == 0 && pb.strip ().length == 0)
                    continue;
                walk_mime_tree (ph, pb, ref plain, ref html, attachments, images, depth + 1);
            }
            return;
        }

        /* message/rfc822 — treat as opaque attachment when it has a payload. */
        if (mime_type.has_prefix ("message/")) {
            var bytes = decode_part_bytes (headers, body);
            if (bytes != null && bytes.get_size () > 0) {
                attachments.add (new Attachment () {
                    filename = mime_filename (headers, ct) ?? _("Forwarded message"),
                    mime_type = mime_type.length > 0 ? mime_type : "message/rfc822",
                    data = bytes,
                });
            }
            return;
        }

        var disposition = (header_value (headers, "content-disposition") ?? "").down ();
        var cid = strip_content_id (header_value (headers, "content-id"));
        var filename = mime_filename (headers, ct);
        var is_image = mime_type.has_prefix ("image/");
        var is_cid_image = is_image && cid.length > 0;
        var is_attachment = disposition.has_prefix ("attachment")
            || (filename != null && filename.length > 0 && !is_cid_image);
        var is_calendar = mime_type == "text/calendar"
            || mime_type == "application/ics";
        var is_signature = mime_type == "application/pkcs7-signature"
            || mime_type == "application/x-pkcs7-signature"
            || mime_type == "application/pgp-signature";

        if (is_signature)
            return;

        if (is_cid_image) {
            var bytes = decode_part_bytes (headers, body);
            if (bytes != null && bytes.get_size () > 0) {
                images.add (new InlineImage () {
                    cid = cid,
                    mime_type = mime_type.length > 0 ? mime_type : "image/png",
                    data = bytes,
                });
            }
            return;
        }

        if (is_attachment && !is_calendar) {
            var bytes = decode_part_bytes (headers, body);
            if (bytes != null && bytes.get_size () > 0) {
                attachments.add (new Attachment () {
                    filename = filename ?? _("Attachment"),
                    mime_type = mime_type.length > 0 ? mime_type : "application/octet-stream",
                    data = bytes,
                });
            }
            return;
        }

        if (mime_type == "text/plain" || mime_type.has_prefix ("text/plain")) {
            if (plain == null)
                plain = decode_part_text (headers, body, ct);
            return;
        }
        if (mime_type == "text/html" || mime_type.has_prefix ("text/html")) {
            if (html == null)
                html = decode_part_text (headers, body, ct);
            return;
        }

        /* Unknown leaf with no disposition — keep first text-ish fallback. */
        if (plain == null && html == null && !mime_type.has_prefix ("application/"))
            plain = decode_part_text (headers, body, ct);
    }

    private static GenericArray<string> split_mime_parts (string body, string boundary) {
        var out_parts = new GenericArray<string> ();
        var marker = "--" + boundary;
        var parts = body.split (marker);
        for (uint i = 0; i < parts.length; i++) {
            var part = parts[i];
            if (part.has_prefix ("--"))
                continue; /* closing --boundary-- */
            if (part.has_prefix ("\r\n"))
                part = part.substring (2);
            else if (part.has_prefix ("\n"))
                part = part.substring (1);
            if (part.has_suffix ("\r\n"))
                part = part.substring (0, part.length - 2);
            else if (part.has_suffix ("\n"))
                part = part.substring (0, part.length - 1);
            if (part.strip ().length == 0)
                continue;
            out_parts.add (part);
        }
        return out_parts;
    }

    private static string mime_type_only (string content_type) {
        var semi = content_type.index_of_char (';');
        var main = (semi > 0 ? content_type.substring (0, semi) : content_type).strip ().down ();
        return main;
    }

    private static string? mime_param (string header_value, string name) {
        var want = name.down () + "=";
        var down = header_value.down ();
        var idx = down.index_of (want);
        if (idx < 0)
            return null;
        var rest = header_value.substring (idx + want.length).strip ();
        if (rest.has_prefix ("\"")) {
            var end = rest.index_of_char ('"', 1);
            if (end > 1)
                return rest.substring (1, end - 1);
        }
        /* token until ; or whitespace */
        var end2 = rest.length;
        for (int i = 0; i < rest.length; i++) {
            var ch = rest[i];
            if (ch == ';' || ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
                end2 = i;
                break;
            }
        }
        return rest.substring (0, end2).strip ();
    }

    private static string? mime_filename (string part_headers, string content_type) {
        var disp = header_value (part_headers, "content-disposition");
        if (disp != null) {
            var fn = mime_param (disp, "filename");
            if (fn != null && fn.length > 0)
                return decode_rfc2047 (fn) ?? fn;
        }
        var name = mime_param (content_type, "name");
        if (name != null && name.length > 0)
            return decode_rfc2047 (name) ?? name;
        return null;
    }

    private static string strip_content_id (string? cid) {
        if (cid == null || cid.length == 0)
            return "";
        var sb = new StringBuilder ();
        for (int i = 0; i < cid.length; i++) {
            var ch = cid[i];
            if (ch == '<' || ch == '>')
                continue;
            sb.append_c (ch);
        }
        return sb.str.strip ();
    }

    private static string rewrite_cid_refs (
        string html,
        GenericArray<InlineImage> images,
        uint64 token
    ) {
        if (token == 0 || images.length == 0)
            return html;
        var done = new bool[images.length];
        var result = html.make_valid ();
        for (uint n = 0; n < images.length; n++) {
            uint best = images.length;
            for (uint i = 0; i < images.length; i++) {
                if (done[i] || images[i].cid == null || images[i].cid.length == 0)
                    continue;
                if (best == images.length || images[i].cid.length > images[best].cid.length)
                    best = i;
            }
            if (best == images.length)
                break;
            done[best] = true;
            var uri = InlineImagePages.uri (token, best);
            var cid = images[best].cid;
            result = replace_literal_imap (result, "cid:" + cid, uri);
            result = replace_literal_imap (result, "CID:" + cid, uri);
            var unescaped = Uri.unescape_string (cid);
            if (unescaped != null && unescaped.length > 0 && unescaped != cid) {
                result = replace_literal_imap (result, "cid:" + unescaped, uri);
                result = replace_literal_imap (result, "CID:" + unescaped, uri);
            }
        }
        return result;
    }

    /* Literal substitute — never Vala string.replace() (GRegex + abort). */
    private static string replace_literal_imap (string text, string old, string replacement) {
        if (text.length == 0 || old.length == 0 || old == replacement)
            return text;
        int index = text.index_of (old);
        if (index < 0)
            return text;
        var builder = new StringBuilder ();
        int start = 0;
        while (index >= 0) {
            builder.append (text.substring (start, index - start));
            builder.append (replacement);
            start = index + old.length;
            index = text.index_of (old, start);
        }
        builder.append (text.substring (start));
        return builder.str;
    }

    private static Bytes? decode_part_bytes (string part_headers, string body) {
        var cte = (header_value (part_headers, "content-transfer-encoding") ?? "").down ().strip ();
        if (cte == "base64") {
            var cleaned = replace_literal_imap (
                replace_literal_imap (replace_literal_imap (body, "\r", ""), "\n", ""),
                " ",
                ""
            ).strip ();
            if (cleaned.length == 0)
                return null;
            try {
                return new Bytes (Base64.decode (cleaned));
            } catch (Error e) {
                return null;
            }
        }
        if (cte == "quoted-printable") {
            var decoded = decode_quoted_printable (body);
            return new Bytes (decoded.data);
        }
        /* 7bit / 8bit / binary */
        return new Bytes (body.data);
    }

    private static string decode_part_text (string part_headers, string body, string content_type) {
        var bytes = decode_part_bytes (part_headers, body);
        if (bytes == null || bytes.get_size () == 0)
            return "";
        unowned uint8[] data = bytes.get_data ();
        /* Empty GBytes may yield a NULL data pointer; g_convert forbids that. */
        if (data == null || data.length == 0)
            return "";
        var charset = normalize_charset (mime_param (content_type, "charset"));
        try {
            return convert ((string) data, data.length, "UTF-8", charset);
        } catch (Error e) {
            /* Binary-safe copy — casting a non-NUL-terminated buffer to string
             * alone can truncate at the first 0x00. */
            var copy = new uint8[data.length + 1];
            Memory.copy (copy, data, data.length);
            copy[data.length] = 0;
            return (string) copy;
        }
    }

    private static string decode_body (string part_headers, string body) {
        var ct = header_value (part_headers, "content-type") ?? "text/plain";
        return decode_part_text (part_headers, body, ct);
    }

    private static string decode_quoted_printable (string input) {
        var sb = new StringBuilder ();
        for (int i = 0; i < input.length; i++) {
            if (input[i] == '=' && i + 2 < input.length) {
                if (input[i + 1] == '\r' && input[i + 2] == '\n') {
                    i += 2;
                    continue;
                }
                if (input[i + 1] == '\n') {
                    i += 1;
                    continue;
                }
                int hi = hex_val (input[i + 1]);
                int lo = hex_val (input[i + 2]);
                if (hi >= 0 && lo >= 0) {
                    sb.append_c ((char) ((hi << 4) | lo));
                    i += 2;
                    continue;
                }
            }
            sb.append_c (input[i]);
        }
        return sb.str;
    }

    private static int hex_val (char c) {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        return -1;
    }

    private static string normalize_charset (string? charset) {
        if (charset == null || charset.length == 0)
            return "UTF-8";
        var c = charset.strip ().down ();
        if (c == "utf8" || c == "utf-8")
            return "UTF-8";
        if (c == "iso-8859-1" || c == "latin1" || c == "latin-1")
            return "ISO-8859-1";
        if (c == "iso-8859-15")
            return "ISO-8859-15";
        if (c == "windows-1252" || c == "cp1252")
            return "WINDOWS-1252";
        return charset;
    }
}
