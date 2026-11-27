/**
 * Letter Graph MailBackend — no Camel / evolution-ews.
 *
 * Folders, headers, body, flags, move/copy, empty folder, sendMail, drafts.
 * peek_folder_remote_counts from Graph totalItemCount / unreadItemCount.
 */
public class Mail.GraphMailBackend : Object, MailBackend {
    /* Regole Globali R3.1 — Graph message list page size (MS allows 1–1000). */
    public const uint LIST_HEADER_CAP = 300;
    /* Until-done walks in short slices so Window can store/paint between
     * chunks (cold Archive must not block 6+ minutes with had=0). */
    public const uint LIST_UNTIL_DONE_PAGES = 3;
    /* Graph JSON fileAttachment limit for sendMail / draft create. */
    private const size_t GRAPH_INLINE_ATTACHMENT_MAX = LetterGraph.Client.INLINE_ATTACHMENT_MAX;

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
    public bool last_list_refresh_authoritative {
        get { return this._last_list_refresh_authoritative; }
    }

    private class FlagJob {
        public Account account;
        public Folder folder;
        public GenericArray<string> uids;
        public bool is_seen; /* false → flagged */
        public bool add;
    }

    private class TransferJob {
        public Account account;
        public Folder from;
        public Folder destination;
        public GenericArray<string> uids;
        public bool delete_original;
    }

    private const int64 BODY_RAM_TTL_US = 10 * 60 * TimeSpan.SECOND;

    private HashTable<string, MessageContent> body_ram;
    private HashTable<string, int64?> body_ram_touched;
    private string? pinned_body_key;
    private uint body_ram_ttl_source;
    private HashTable<string, MessageContent> local_outgoing_bodies;
    private HashTable<string, int> folder_exists;
    private HashTable<string, int> folder_unseen;
    private HashTable<string, GenericArray<Folder>> folder_list_cache;
    /* @odata.nextLink + accumulated headers across until-done slices. */
    private HashTable<string, string> header_list_next;
    private HashTable<string, GenericArray<Message>> header_list_accum;
    /* I2 body prefetch cursor (index into newest-first header list). */
    private HashTable<string, int> prefetch_cursor;
    private GenericArray<FlagJob> flag_queue;
    private GenericArray<TransferJob> transfer_queue;
    private HashTable<string, uint8> folders_pending_flags;
    private HashTable<string, uint8> retired_uids;
    private IdentityCatalog catalog = new IdentityCatalog ();
    private Mutex io_lock;
    private bool flush_running;
    /* Soft-mutation registry on disk (Regole Globali R1.2). */
    private uint registry_save_source;
    private bool registry_loaded;
    private BodyTextIndex body_text_index = new BodyTextIndex ();
    public GraphBodyWorker body_worker { get; private set; }

    public GraphMailBackend () {
        this.body_ram = new HashTable<string, MessageContent> (str_hash, str_equal);
        this.body_ram_touched = new HashTable<string, int64?> (str_hash, str_equal);
        this.local_outgoing_bodies = new HashTable<string, MessageContent> (str_hash, str_equal);
        this.folder_exists = new HashTable<string, int> (str_hash, str_equal);
        this.folder_unseen = new HashTable<string, int> (str_hash, str_equal);
        this.folder_list_cache = new HashTable<string, GenericArray<Folder>> (str_hash, str_equal);
        this.header_list_next = new HashTable<string, string> (str_hash, str_equal);
        this.header_list_accum = new HashTable<string, GenericArray<Message>> (str_hash, str_equal);
        this.prefetch_cursor = new HashTable<string, int> (str_hash, str_equal);
        this.flag_queue = new GenericArray<FlagJob> ();
        this.transfer_queue = new GenericArray<TransferJob> ();
        this.folders_pending_flags = new HashTable<string, uint8> (str_hash, str_equal);
        this.retired_uids = new HashTable<string, uint8> (str_hash, str_equal);
        this.body_worker = new GraphBodyWorker ();
        this.io_lock = Mutex ();
        this.body_ram_ttl_source = Timeout.add_seconds (60, () => {
            sweep_body_ram_ttl ();
            return Source.CONTINUE;
        });
        try {
            this.catalog = IdentityCatalog.load ();
        } catch (Error e) {
            warning ("GraphMailBackend: identity catalog: %s", e.message);
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
        new Thread<void*> ("letter-graph-folders", () => {
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

    private class GraphFolderNode {
        public Folder folder;
        public string id;
        public GenericArray<GraphFolderNode> children = new GenericArray<GraphFolderNode> ();
    }

    private GenericArray<Folder> list_folders_sync (
        Account account,
        Cancellable? cancellable
    ) throws Error {
        var client = open_client (account);
        var infos = client.list_mail_folders_sync (cancellable);
        var by_id = new HashTable<string, GraphFolderNode> (str_hash, str_equal);
        var roots = new GenericArray<GraphFolderNode> ();

        for (uint i = 0; i < infos.length; i++) {
            var info = infos[i];
            var folder = new Folder () {
                name = info.display_name,
                full_name = info.id,
                flags = 0,
                indent = 0,
                has_children = false,
                server_total = (int) info.total_item_count,
                server_unread = (int) info.unread_item_count,
                total = (int) info.total_item_count,
                unread = (int) info.unread_item_count,
            };
            MailSession.apply_folder_display_name (folder);

            /* Letter owns the virtual :outbox; never show Graph’s server Outbox. */
            if (folder.kind == FolderKind.OUTBOX)
                continue;

            var key = folder_key (account, folder);
            this.folder_exists.set (key, folder.server_total);
            this.folder_unseen.set (key, folder.server_unread);

            by_id.set (info.id, new GraphFolderNode () {
                folder = folder,
                id = info.id,
            });
        }

        for (uint i = 0; i < infos.length; i++) {
            var info = infos[i];
            var node = by_id.get (info.id);
            if (node == null)
                continue;
            var parent_id = info.parent_id;
            GraphFolderNode? parent = null;
            if (parent_id != null && parent_id.length > 0)
                parent = by_id.get (parent_id);
            if (parent != null) {
                parent.children.add (node);
                parent.folder.has_children = true;
            } else {
                roots.add (node);
            }
        }

        sort_graph_folder_nodes (roots);
        var folders = new GenericArray<Folder> ();
        flatten_graph_folder_nodes (roots, 0, folders);
        this.folder_list_cache.set (account.uid, folders);
        return folders;
    }

    private static void sort_graph_folder_nodes (GenericArray<GraphFolderNode> nodes) {
        nodes.sort_with_data ((a, b) => {
            int rank = a.folder.sort_rank - b.folder.sort_rank;
            if (rank != 0)
                return rank;
            return a.folder.name.collate (b.folder.name);
        });
        for (uint i = 0; i < nodes.length; i++)
            sort_graph_folder_nodes (nodes[i].children);
    }

    private static void flatten_graph_folder_nodes (
        GenericArray<GraphFolderNode> nodes,
        uint indent,
        GenericArray<Folder> folders
    ) {
        for (uint i = 0; i < nodes.length; i++) {
            var node = nodes[i];
            /* Promote children of hidden SYSTEM folders to this indent. */
            if (node.folder.hidden) {
                flatten_graph_folder_nodes (node.children, indent, folders);
                continue;
            }
            node.folder.indent = indent;
            node.folder.has_children = false;
            for (uint c = 0; c < node.children.length; c++) {
                if (!node.children[c].folder.hidden) {
                    node.folder.has_children = true;
                    break;
                }
            }
            folders.add (node.folder);
            flatten_graph_folder_nodes (node.children, indent + 1, folders);
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
        this._header_sync_busy = true;
        this._last_list_refresh_incomplete = false;
        this._last_list_refresh_failed = false;
        this._last_list_refresh_completed = false;
        this._last_list_refresh_authoritative = false;

        if (!refresh && previous != null && previous.length > 0) {
            this._header_sync_busy = false;
            this._last_list_refresh_completed = true;
            this._last_list_refresh_authoritative = true;
            return previous;
        }

        GenericArray<Message>? result = null;
        Error? error = null;
        bool incomplete = false;
        var until_done = refresh_timeout_seconds == MailSession.REFRESH_INFO_FORCE_UNTIL_DONE;
        SourceFunc callback = list_messages.callback;
        new Thread<void*> ("letter-graph-list", () => {
            try {
                result = list_messages_sync (
                    account,
                    folder,
                    until_done,
                    out incomplete,
                    previous,
                    high,
                    cancellable
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

        this._header_sync_busy = false;
        if (error != null) {
            this._last_list_refresh_failed = true;
            throw error;
        }
        this._last_list_refresh_incomplete = incomplete;
        this._last_list_refresh_completed = !incomplete;
        this._last_list_refresh_authoritative = !incomplete;
        var listed = result ?? new GenericArray<Message> ();
        /* Tip (incomplete): merge into prior Letter headers and overlay
         * seen/flagged so F5 picks up Outlook web changes without dropping
         * older UIDs. Until-done chunks already carry the walk-so-far —
         * only merge when still behind a warm prior (lost-cursor catch-up)
         * so mid-walk does not replace 15k local with a shorter Graph head. */
        if (incomplete && previous != null && previous.length > 0) {
            if (!until_done)
                listed = merge_tip_into_previous (previous, listed);
            else if (listed.length < previous.length)
                listed = merge_tip_into_previous (previous, listed);
        }
        return listed;
    }

    private static GenericArray<Message> merge_tip_into_previous (
        GenericArray<Message> previous,
        GenericArray<Message> incoming
    ) {
        var have = new HashTable<string, Message> (str_hash, str_equal);
        var result = new GenericArray<Message> ();
        for (uint i = 0; i < previous.length; i++) {
            result.add (previous[i]);
            if (previous[i].uid != null && previous[i].uid.length > 0)
                have.set (previous[i].uid, previous[i]);
        }
        for (uint i = 0; i < incoming.length; i++) {
            var uid = incoming[i].uid;
            if (uid == null || uid.length == 0)
                continue;
            var prior = have.get (uid);
            if (prior != null) {
                prior.seen = incoming[i].seen;
                prior.flagged = incoming[i].flagged;
                prior.has_attachment = incoming[i].has_attachment
                    || prior.has_attachment;
                if (incoming[i].to != null && incoming[i].to.length > 0)
                    prior.to = incoming[i].to;
                if (incoming[i].outgoing) {
                    prior.outgoing = true;
                    if (prior.to != null && prior.to.length > 0)
                        prior.list_address = prior.to;
                }
                if (incoming[i].conversation_key != null
                    && incoming[i].conversation_key.length > 0)
                    prior.conversation_key = incoming[i].conversation_key;
                continue;
            }
            have.set (uid, incoming[i]);
            result.add (incoming[i]);
        }
        return result;
    }

    private GenericArray<Message> list_messages_sync (
        Account account,
        Folder folder,
        bool until_done,
        out bool incomplete,
        GenericArray<Message>? previous,
        bool from_head,
        Cancellable? cancellable
    ) throws Error {
        incomplete = false;
        var client = open_client (account);
        var key = folder_key (account, folder);
        /* Tip = one page from the head (in-memory cursor only).
         * Until-done = short slices via @odata.nextLink so Window can persist
         * and paint between chunks — never wait for 27k headers in one call.
         * nextLink is also on disk so a quit mid-Archive resumes, not
         * re-downloads the newest 15k. Update Folder (from_head) discards it. */
        uint max_pages = until_done ? LIST_UNTIL_DONE_PAGES : 1;
        string? resume = null;
        bool resumed_cursor = false;
        if (!until_done) {
            this.header_list_next.remove (key);
            this.header_list_accum.remove (key);
            /* Keep on-disk nextLink — a tip must not abandon catch-up. */
        } else if (from_head) {
            this.header_list_next.remove (key);
            this.header_list_accum.remove (key);
            clear_graph_next_link (account, folder);
        } else if (this.header_list_next.contains (key)) {
            resume = this.header_list_next.get (key);
            resumed_cursor = true;
        } else {
            resume = load_graph_next_link (account, folder);
            if (resume != null && resume.length > 0) {
                resumed_cursor = true;
                this.header_list_next.set (key, resume);
                Utils.sync_log_detail (
                    "graph headers “%s” resume nextLink from disk".printf (folder.name)
                );
            } else {
                /* Fresh until-done — drop a stale mid-walk accum. */
                this.header_list_accum.remove (key);
            }
        }
        bool more = false;
        string? next_url = null;
        var headers = client.list_folder_headers_sync (
            folder.full_name,
            LIST_HEADER_CAP,
            max_pages,
            out more,
            resume,
            out next_url,
            cancellable
        );
        var chunk = new GenericArray<Message> ();
        var outgoing_folder = folder.kind == FolderKind.SENT
            || folder.kind == FolderKind.DRAFTS;
        for (uint i = 0; i < headers.length; i++) {
            var h = headers[i];
            var from_raw = h.from ?? _("Unknown sender");
            var to_raw = h.to ?? "";
            var date = parse_graph_datetime (h.received);
            chunk.add (new Message () {
                uid = h.id,
                subject = h.subject ?? _("(No subject)"),
                from = from_raw,
                to = to_raw,
                /* ContactStore harvest reads to_header (raw with @), not to. */
                to_header = to_raw.length > 0 ? to_raw : null,
                date = date,
                preview = Utils.sanitize_message_preview (h.preview),
                seen = h.seen,
                flagged = h.flagged,
                has_attachment = h.has_attachment,
                folder_name = folder.name,
                folder_full_name = folder.full_name,
                outgoing = outgoing_folder,
                list_address = outgoing_folder && to_raw.length > 0 ? to_raw : from_raw,
                msgid_hash = MailSession.hash_message_id_raw (h.internet_message_id),
                conversation_key = graph_conversation_key (h.conversation_id),
            });
        }

        GenericArray<Message> listed;
        if (until_done) {
            var accum = this.header_list_accum.get (key);
            if (accum == null) {
                accum = new GenericArray<Message> ();
                /* Seed prior headers when resuming a nextLink (restart /
                 * tip→escalate). Warm Update Folder from the head stays
                 * empty so vanished Graph ids can drop at the finish. */
                if (previous != null && previous.length > 0
                    && (resumed_cursor || previous.length <= LIST_HEADER_CAP)) {
                    for (uint i = 0; i < previous.length; i++)
                        accum.add (previous[i]);
                }
                this.header_list_accum.set (key, accum);
            }
            append_headers_unique (accum, chunk);
            if (more && next_url != null && next_url.length > 0) {
                this.header_list_next.set (key, next_url);
                save_graph_next_link (account, folder, next_url);
            } else {
                this.header_list_next.remove (key);
                this.header_list_accum.remove (key);
                clear_graph_next_link (account, folder);
            }
            listed = clone_message_array (accum);
            incomplete = more;
            Utils.sync_log (
                "graph headers until-done “%s” → %u%s".printf (
                    folder.name,
                    listed.length,
                    incomplete ? " (more pending)" : ""
                )
            );
        } else {
            /* Tip clears any on-disk nextLink (authoritative until-done
             * must start from the head unless a chunk cursor exists). */
            listed = chunk;
            incomplete = more;
            if (listed.length == 0) {
                Utils.sync_log_detail (
                    "graph headers tip “%s” → 0".printf (folder.name)
                );
            } else {
                Utils.sync_log_detail (
                    "graph headers tip “%s” → %u%s".printf (
                        folder.name,
                        listed.length,
                        more ? " (more pending)" : ""
                    )
                );
            }
        }
        /* Folder list said mail exists but messages came back empty — soft
         * incomplete so Window retries instead of painting “Nessun messaggio”. */
        if (this.folder_exists.contains (key)
            && this.folder_exists.get (key) > 0
            && listed.length == 0
            && !incomplete) {
            Utils.sync_log_detail (
                "graph headers “%s” empty vs folder_exists %d — mark incomplete".printf (
                    folder.name,
                    this.folder_exists.get (key)
                )
            );
            incomplete = true;
        }
        return listed;
    }

    private static void append_headers_unique (
        GenericArray<Message> dest,
        GenericArray<Message> incoming
    ) {
        var have = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < dest.length; i++) {
            if (dest[i].uid != null && dest[i].uid.length > 0)
                have.set (dest[i].uid, 1);
        }
        for (uint i = 0; i < incoming.length; i++) {
            var uid = incoming[i].uid;
            if (uid == null || uid.length == 0 || have.contains (uid))
                continue;
            have.set (uid, 1);
            dest.add (incoming[i]);
        }
    }

    private static GenericArray<Message> clone_message_array (GenericArray<Message> src) {
        var out = new GenericArray<Message> ();
        for (uint i = 0; i < src.length; i++)
            out.add (src[i]);
        return out;
    }

    private static string graph_next_link_file (Account account, Folder folder) {
        return MailSession.header_list_cache_file (
            account.source_uid ?? account.uid,
            folder.full_name
        ) + ".graph-next";
    }

    private static string? load_graph_next_link (Account account, Folder folder) {
        var path = graph_next_link_file (account, folder);
        if (!FileUtils.test (path, FileTest.IS_REGULAR))
            return null;
        string contents;
        try {
            FileUtils.get_contents (path, out contents);
        } catch (Error e) {
            return null;
        }
        var url = contents.strip ();
        if (url.length == 0 || !url.has_prefix ("https://"))
            return null;
        return url;
    }

    private static void save_graph_next_link (Account account, Folder folder, string url) {
        if (url.length == 0 || !url.has_prefix ("https://"))
            return;
        var path = graph_next_link_file (account, folder);
        var dir = Path.get_dirname (path);
        try {
            DirUtils.create_with_parents (dir, 0700);
            FileUtils.set_contents (path, url + "\n");
        } catch (Error e) {
            warning ("Graph nextLink save “%s”: %s", folder.name, e.message);
        }
    }

    private static void clear_graph_next_link (Account account, Folder folder) {
        var path = graph_next_link_file (account, folder);
        if (!FileUtils.test (path, FileTest.EXISTS))
            return;
        FileUtils.unlink (path);
    }

    public async void follow_folder (Account account, Folder folder) throws Error {
        /* No Graph webhook / delta watch in slice 1. */
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
        var dir = body_file (account, folder, "_").get_parent ();
        if (dir == null || !dir.query_exists (cancellable))
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
                if (name == null || !name.has_suffix (".json"))
                    continue;
                var uid = name.substring (0, name.length - 5);
                if (uid.length == 0 || uid == "_")
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
            warning ("GraphMailBackend index list “%s”: %s", folder.name, e.message);
            return 0;
        }
        if (pending.length == 0)
            return 0;

        var plains = new GenericArray<string> ();
        var uids_ok = new GenericArray<string> ();
        Error? index_error = null;
        SourceFunc callback = index_more_cached_bodies.callback;
        var acc = account;
        var fold = folder;
        new Thread<void*> ("letter-graph-body-index", () => {
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
                        var content = content_from_cache_json (data);
                        if (content == null)
                            continue;
                        var plain = searchable_plain (content);
                        if (plain == null || plain.strip ().length == 0)
                            plain = "";
                        uids_ok.add (uid);
                        plains.add (plain);
                    } catch (Error e) {
                        if (e is IOError.CANCELLED)
                            throw e;
                        debug ("GraphMailBackend index file %s: %s", uid, e.message);
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
                "graph body index “%s” +%u".printf (folder.name, added)
            );
        }
        return added;
    }

    public async int local_uid_count (
        Account account,
        Folder folder,
        Cancellable? cancellable = null
    ) throws Error {
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
            total = 0;
            unread = 0;
            return false;
        }
        total = this.folder_exists.get (key);
        unread = this.folder_unseen.contains (key) ? this.folder_unseen.get (key) : 0;
        return true;
    }

    /* Dedicated GET mailFolders/{id} — fresh totalItemCount (not tree list). */
    public async bool refresh_folder_counts (
        Account account,
        Folder folder,
        Cancellable? cancellable = null
    ) throws Error {
        if (folder.is_virtual_view || folder.full_name == null || folder.full_name.length == 0)
            return false;
        if (!Account.looks_like_graph_folder_id (folder.full_name))
            return false;

        LetterGraph.FolderInfo? info = null;
        Error? fetch_error = null;
        SourceFunc callback = refresh_folder_counts.callback;
        var folder_id = folder.full_name;
        new Thread<void*> ("letter-graph-folder-count", () => {
            try {
                var client = open_client (account);
                info = client.get_mail_folder_sync (folder_id, cancellable);
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
        if (fetch_error != null) {
            if (fetch_error is IOError.CANCELLED || Utils.is_cancelled_error (fetch_error))
                throw fetch_error;
            warning ("GraphMailBackend folder count “%s”: %s", folder.name, fetch_error.message);
            return false;
        }
        if (info == null)
            return false;

        apply_folder_count_info (account, folder, info);
        Utils.sync_log_detail (
            "graph folder GET “%s” total=%lld unread=%lld".printf (
                folder.name,
                info.total_item_count,
                info.unread_item_count
            )
        );
        return true;
    }

    private void apply_folder_count_info (
        Account account,
        Folder folder,
        LetterGraph.FolderInfo info
    ) {
        folder.server_total = (int) info.total_item_count;
        folder.server_unread = (int) info.unread_item_count;
        folder.total = (int) info.total_item_count;
        folder.unread = (int) info.unread_item_count;
        var key = folder_key (account, folder);
        this.folder_exists.set (key, folder.server_total);
        this.folder_unseen.set (key, folder.server_unread);
        /* Keep sidebar cache row in sync when present. */
        var cached = this.folder_list_cache.get (account.uid);
        if (cached == null)
            return;
        for (uint i = 0; i < cached.length; i++) {
            if (cached[i].full_name == folder.full_name) {
                cached[i].server_total = folder.server_total;
                cached[i].server_unread = folder.server_unread;
                cached[i].total = folder.total;
                cached[i].unread = folder.unread;
                break;
            }
        }
    }

    public void unwatch_all_folders () {
    }

    public GenericArray<string> apply_live_flags (
        Account account,
        Folder folder,
        GenericArray<Message> messages
    ) {
        return new GenericArray<string> ();
    }

    public uint append_live_headers (
        Account account,
        Folder folder,
        GenericArray<Message> messages
    ) {
        return 0;
    }

    public MessageContent? peek_body (Account account, Folder folder, string uid) {
        var local = this.local_outgoing_bodies.get (uid);
        if (local != null)
            return local;
        var key = body_key (account, folder, uid);
        var ram = this.body_ram.get (key);
        if (ram != null)
            touch_body_ram (key);
        return ram;
    }

    public async MessageContent? try_load_body_from_disk (
        Account account,
        Folder folder,
        string uid,
        Cancellable? cancellable = null
    ) throws Error {
        var ram = peek_body (account, folder, uid);
        if (ram != null) {
            pin_body_ram (body_key (account, folder, uid));
            return ram;
        }
        /* local-sent-* lives under outgoing/, not the Sent folder body dir. */
        if (uid.has_prefix ("local-sent-") || uid.has_prefix ("local-draft-")) {
            var outgoing = local_outgoing_body_file (account, uid);
            if (outgoing.query_exists (cancellable)) {
                uint8[] odata;
                yield outgoing.load_contents_async (cancellable, out odata, null);
                var ocontent = content_from_cache_json (odata);
                if (ocontent != null) {
                    attach_parts_from_disk (account, folder, uid, ocontent);
                    apply_inline_rewrite (ocontent);
                    this.local_outgoing_bodies.set (uid, ocontent);
                    return ocontent;
                }
            }
            return null;
        }
        var file = body_file (account, folder, uid);
        if (!file.query_exists (cancellable))
            return null;
        uint8[] data;
        yield file.load_contents_async (cancellable, out data, null);
        var content = content_from_cache_json (data);
        if (content == null)
            return null;
        attach_parts_from_disk (account, folder, uid, content);
        apply_inline_rewrite (content);
        remember_body_ram (account, folder, uid, content);
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
        /* Body first — attachments hydrate separately (progressive open). */
        var cached = yield try_load_body_from_disk (account, folder, uid, cancellable);
        if (cached != null)
            return cached;

        if (!is_graph_message_id (uid)) {
            throw new IOError.NOT_FOUND (
                _("This sent copy is only on this device and its body is missing.")
            );
        }

        LetterGraph.MessageBody? body = null;
        Error? fetch_error = null;
        SourceFunc callback = load_message.callback;
        new Thread<void*> ("letter-graph-body", () => {
            try {
                var client = open_client (account);
                body = client.fetch_message_body_sync (uid, cancellable);
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
        if (body == null)
            throw new IOError.FAILED (_("Empty Graph body"));

        var content = content_from_graph_body (body);
        store_body_cache (account, folder, uid, content);
        return content;
    }

    public async void hydrate_message_attachments (
        Account account,
        Folder folder,
        string uid,
        MessageContent content,
        Cancellable? cancellable = null
    ) throws Error {
        if (!is_graph_message_id (uid))
            return;
        if (graph_parts_complete_on_disk (account, folder, uid, content)) {
            attach_parts_from_disk (account, folder, uid, content);
            remember_body_ram (account, folder, uid, content);
            apply_inline_rewrite (content);
            return;
        }
        yield fetch_and_store_graph_parts (account, folder, uid, content, cancellable);
    }

    private async void fetch_and_store_graph_parts (
        Account account,
        Folder folder,
        string uid,
        MessageContent content,
        Cancellable? cancellable
    ) throws Error {
        GenericArray<Attachment>? files = null;
        GenericArray<InlineImage>? inlines = null;
        Error? fetch_error = null;
        SourceFunc callback = fetch_and_store_graph_parts.callback;
        new Thread<void*> ("letter-graph-att", () => {
            try {
                var client = open_client (account);
                GenericArray<Attachment> f;
                GenericArray<InlineImage> i;
                client.fetch_message_parts_sync (uid, out f, out i, cancellable);
                files = f;
                inlines = i;
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

        content.attachments = (files != null && files.length > 0) ? files : null;
        content.inline_images = (inlines != null && inlines.length > 0) ? inlines : null;
        persist_attachment_sidecars (account, folder, uid, content);
        drop_attachment_bytes_after_disk (content);
        /* Persist cid: HTML — letterimg: tokens are session-only. */
        store_body_cache (account, folder, uid, content);
        apply_inline_rewrite (content);
    }

    private void store_body_cache (
        Account account,
        Folder folder,
        string uid,
        MessageContent content
    ) {
        remember_body_ram (account, folder, uid, content);
        try {
            var file = body_file (account, folder, uid);
            var parent = file.get_parent ();
            if (parent != null && !parent.query_exists (null))
                parent.make_directory_with_parents (null);
            file.replace_contents (
                content_to_cache_json (content).data,
                null,
                false,
                FileCreateFlags.PRIVATE,
                null,
                null
            );
            index_body_content (account, folder, uid, content);
        } catch (Error e) {
            warning ("GraphMailBackend: body cache write: %s", e.message);
        }
    }

    public async void export_message_eml (
        Account account,
        Folder folder,
        string uid,
        File dest,
        Cancellable? cancellable = null
    ) throws Error {
        if (!is_graph_message_id (uid)) {
            throw new IOError.NOT_SUPPORTED (
                _("This copy is only on this device and cannot be exported as EML.")
            );
        }
        Bytes? mime = null;
        Error? push_error = null;
        SourceFunc callback = export_message_eml.callback;
        var acc = account;
        var mid = uid;
        new Thread<void*> ("letter-graph-eml", () => {
            try {
                var client = open_client (acc);
                mime = client.fetch_message_mime_sync (mid, cancellable);
            } catch (Error e) {
                push_error = e;
            }
            Idle.add (() => {
                callback ();
                return Source.REMOVE;
            });
            return null;
        });
        yield;
        if (push_error != null)
            throw push_error;
        if (mime == null || mime.get_size () == 0)
            throw new IOError.FAILED (_("Empty Graph MIME export."));
        unowned uint8[] raw = mime.get_data ();
        dest.replace_contents (
            raw,
            null,
            false,
            FileCreateFlags.NONE,
            null,
            cancellable
        );
    }

    public void queue_mark_seen (Account account, Folder folder, string uid) {
        var uids = new GenericArray<string> ();
        uids.add (uid);
        enqueue_flag_job (account, folder, uids, true, true);
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
        enqueue_flag_job (account, folder, uids, true, seen);
    }

    public async uint prefetch_recent (
        Account account,
        Folder folder,
        GenericArray<Message> listed,
        int days,
        Cancellable? cancellable = null,
        int max_index = -1
    ) throws Error {
        /* Regole Globali I2 / R5.1 — body-cache-days window, newest first,
         * small chunks. Attachments hydrate on open (I5). */
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
        var cursor_key = folder_key (account, folder);
        int start = this.prefetch_cursor.contains (cursor_key)
            ? this.prefetch_cursor.get (cursor_key)
            : 0;
        if (start < 0 || start > (int) listed.length)
            start = 0;

        var window_end = (int) listed.length;
        if (max_index >= 0)
            window_end = int.min (max_index + 1, window_end);
        if (start >= window_end) {
            this.prefetch_cursor.set (cursor_key, 0);
            return 0;
        }

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
            if (!is_graph_message_id (message.uid))
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
        if (want.length == 0) {
            var next_empty = reached_end ? 0 : i;
            this.prefetch_cursor.set (cursor_key, next_empty);
            if (start > 0 || skipped_disk > 0) {
                Utils.sync_log_detail (
                    "graph prefetch “%s” cursor=%d/%d skipped-disk=%u (no fetch)".printf (
                        folder.name,
                        next_empty,
                        window_end,
                        skipped_disk
                    )
                );
            }
            return 0;
        }

        var got_uids = new GenericArray<string> ();
        var got_bodies = new GenericArray<MessageContent> ();
        Error? prefetch_error = null;
        SourceFunc callback = prefetch_recent.callback;
        var acc = account;
        new Thread<void*> ("letter-graph-prefetch", () => {
            try {
                var client = open_client (acc);
                for (uint u = 0; u < want.length; u++) {
                    if (cancellable != null && cancellable.is_cancelled ())
                        break;
                    var uid = want[u];
                    var body = client.fetch_message_body_sync (uid, cancellable);
                    if (body == null)
                        continue;
                    got_uids.add (uid);
                    got_bodies.add (content_from_graph_body (body));
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
        if (prefetch_error != null
            && !(prefetch_error is IOError.CANCELLED)
            && !Utils.is_cancelled_error (prefetch_error))
            throw prefetch_error;

        for (uint u = 0; u < got_uids.length; u++)
            store_body_cache (account, folder, got_uids[u], got_bodies[u]);

        var fetched = got_uids.length;
        var next = reached_end && want.length < limit ? 0 : i;
        this.prefetch_cursor.set (cursor_key, next);
        Utils.sync_log_detail (
            "graph prefetch “%s” +%u (cursor %d/%d, skipped-disk %u)".printf (
                folder.name,
                fetched,
                next,
                window_end,
                skipped_disk
            )
        );
        return fetched;
    }

    public void reset_prefetch_progress (Account? account = null) {
        if (account == null) {
            this.prefetch_cursor.remove_all ();
            return;
        }
        var prefix = "%s\n".printf (account.uid);
        var keys = new GenericArray<string> ();
        this.prefetch_cursor.foreach ((key, val) => {
            if (key.has_prefix (prefix))
                keys.add (key);
        });
        for (uint i = 0; i < keys.length; i++)
            this.prefetch_cursor.remove (keys[i]);
    }

    public void flush_prefetch_progress () {
    }

    public void release_transient_memory () {
        flush_body_ram_unpinned ();
    }

    public void relieve_memory_pressure () {
        sweep_body_ram_ttl ();
        flush_body_ram_unpinned ();
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
        enqueue_transfer_job (account, from, destination, uids, false);
        return uid;
    }

    public void enqueue_move_messages (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        GenericArray<Message>? messages
    ) {
        enqueue_transfer_job (account, from, destination, uids, true);
    }

    public void cancel_queued_moves (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        bool delete_original = true
    ) {
        for (int i = (int) this.transfer_queue.length - 1; i >= 0; i--) {
            var job = this.transfer_queue[(uint) i];
            if ((job.account.source_uid ?? job.account.uid)
                    != (account.source_uid ?? account.uid)
                || job.from.full_name != from.full_name
                || job.destination.full_name != destination.full_name
                || job.delete_original != delete_original)
                continue;
            for (uint u = 0; u < uids.length; u++) {
                for (int j = (int) job.uids.length - 1; j >= 0; j--) {
                    if (job.uids[(uint) j] == uids[u]) {
                        job.uids.remove_index ((uint) j);
                        if (delete_original)
                            unretire_moved_uid (account, from, uids[u]);
                    }
                }
            }
            if (job.uids.length == 0)
                this.transfer_queue.remove_index ((uint) i);
        }
    }

    public void enqueue_copy_messages (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        GenericArray<Message>? messages
    ) {
        enqueue_transfer_job (account, from, destination, uids, false);
    }

    public void flush_pending_local_changes () {
        flush_pending_mutations_async.begin ((obj, res) => {
            try {
                flush_pending_mutations_async.end (res);
            } catch (Error e) {
                warning ("GraphMailBackend flush: %s", e.message);
            }
        });
    }

    public bool has_blocking_local_flushes () {
        return this.flag_queue.length > 0
            || this.transfer_queue.length > 0
            || this.flush_running;
    }

    public void unpark_heavy_transfers () {
    }

    public async bool flush_pending_local_changes_with_timeout (uint seconds) {
        var done = false;
        var timed_out = false;
        uint timeout_id = 0;
        if (seconds > 0) {
            timeout_id = Timeout.add_seconds (seconds, () => {
                timed_out = true;
                timeout_id = 0;
                if (!done)
                    flush_pending_local_changes_with_timeout.callback ();
                return Source.REMOVE;
            });
        }
        yield flush_pending_mutations_async ();
        done = true;
        if (timeout_id != 0)
            Source.remove (timeout_id);
        var clear = !timed_out
            && this.flag_queue.length == 0
            && this.transfer_queue.length == 0;
        if (clear)
            clear_registry_file ();
        else
            persist_mutation_registry_now ();
        return clear;
    }

    public void persist_mutation_registry_now () {
        if (this.registry_save_source != 0) {
            Source.remove (this.registry_save_source);
            this.registry_save_source = 0;
        }
        if (this.flag_queue.length == 0 && this.transfer_queue.length == 0) {
            clear_registry_file ();
            return;
        }
        try {
            File.new_for_path (graph_registry_dir ()).make_directory_with_parents ();
        } catch (Error e) {
            if (!(e is IOError.EXISTS)) {
                warning ("GraphMailBackend registry dir: %s", e.message);
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
            key.set_boolean (group, "is_seen", job.is_seen);
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
            key.save_to_file (graph_registry_file ());
            Utils.sync_log ("graph mutation registry saved (%u flags, %u transfers)".printf (
                this.flag_queue.length,
                this.transfer_queue.length
            ));
        } catch (Error e) {
            warning ("GraphMailBackend registry write: %s", e.message);
        }
    }

    public uint load_mutation_registry () {
        if (this.registry_loaded)
            return 0;
        this.registry_loaded = true;
        var path = graph_registry_file ();
        if (!FileUtils.test (path, FileTest.IS_REGULAR))
            return 0;
        KeyFile key;
        try {
            key = new KeyFile ();
            key.load_from_file (path, KeyFileFlags.NONE);
        } catch (Error e) {
            warning ("GraphMailBackend registry read: %s", e.message);
            return 0;
        }
        uint loaded = 0;
        try {
            var flag_n = key.get_integer ("meta", "flags");
            for (int i = 0; i < flag_n; i++) {
                var group = "flag-%d".printf (i);
                var account = account_by_id (key.get_string (group, "account"));
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
                    is_seen = key.get_boolean (group, "is_seen"),
                    add = key.get_boolean (group, "add"),
                });
                this.folders_pending_flags.set (folder_key (account, folder), 1);
                loaded++;
            }
            var transfer_n = key.get_integer ("meta", "transfers");
            for (int i = 0; i < transfer_n; i++) {
                var group = "transfer-%d".printf (i);
                var account = account_by_id (key.get_string (group, "account"));
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
                if (key.get_boolean (group, "delete_original")) {
                    for (uint u = 0; u < uids.length; u++)
                        retire_moved_uid (account, from, uids[u]);
                }
                loaded++;
            }
        } catch (Error e) {
            warning ("GraphMailBackend registry parse: %s", e.message);
        }
        if (loaded > 0)
            Utils.sync_log ("graph mutation registry loaded %u job(s)".printf (loaded));
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
        return this.flag_queue.length > 0
            || this.transfer_queue.length > 0
            || this.flush_running;
    }

    public async void flush_pending_local_changes_async () {
        yield flush_pending_mutations_async ();
        if (this.flag_queue.length == 0 && this.transfer_queue.length == 0)
            clear_registry_file ();
        else
            persist_mutation_registry_now ();
    }

    /* R4.1 — flush only jobs whose from/dest (or flag folder) is scope. */
    public async void flush_pending_local_changes_for_folder (
        Account account,
        Folder folder
    ) {
        yield flush_pending_mutations_scoped_async (account, folder);
        if (this.flag_queue.length == 0 && this.transfer_queue.length == 0)
            clear_registry_file ();
        else
            persist_mutation_registry_now ();
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
        yield delete_uids (account, folder, uids, trash);
    }

    public async void delete_message_local (
        Account account,
        Folder folder,
        string uid
    ) throws Error {
        retire_moved_uid (account, folder, uid);
    }

    public async void delete_uids (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        Folder? trash
    ) throws Error {
        if (trash != null && trash.full_name != folder.full_name) {
            enqueue_transfer_job (account, folder, trash, uids, true);
            return;
        }
        /* Permanent purge (Empty Trash path / hard-delete). */
        Error? push_error = null;
        SourceFunc callback = delete_uids.callback;
        var acc = account;
        var copy = new GenericArray<string> ();
        for (uint i = 0; i < uids.length; i++)
            copy.add (uids[i]);
        new Thread<void*> ("letter-graph-purge", () => {
            try {
                var client = open_client (acc);
                for (uint i = 0; i < copy.length; i++) {
                    try {
                        client.permanent_delete_message_sync (copy[i], null);
                    } catch (Error e) {
                        /* Fall back to soft DELETE when permanentDelete is unavailable. */
                        client.delete_message_sync (copy[i], null);
                    }
                    retire_moved_uid (acc, folder, copy[i]);
                }
            } catch (Error e) {
                push_error = e;
            }
            Idle.add (() => {
                callback ();
                return Source.REMOVE;
            });
            return null;
        });
        yield;
        if (push_error != null)
            throw push_error;
    }

    public async void empty_folder (Account account, Folder folder) throws Error {
        if (folder.is_virtual_view || folder.is_gmail_namespace)
            return;

        Error? push_error = null;
        uint purged = 0;
        SourceFunc callback = empty_folder.callback;
        var acc = account;
        var folder_id = folder.full_name;
        new Thread<void*> ("letter-graph-empty", () => {
            try {
                var client = open_client (acc);
                var ids = client.list_folder_message_ids_sync (folder_id, null);
                for (uint i = 0; i < ids.length; i++) {
                    try {
                        client.permanent_delete_message_sync (ids[i], null);
                    } catch (Error e) {
                        client.delete_message_sync (ids[i], null);
                    }
                    purged++;
                }
                this.folder_exists.set (folder_key (acc, folder), 0);
                this.folder_unseen.set (folder_key (acc, folder), 0);
            } catch (Error e) {
                push_error = e;
            }
            Idle.add (() => {
                callback ();
                return Source.REMOVE;
            });
            return null;
        });
        yield;
        if (push_error != null)
            throw push_error;

        var wiped = wipe_folder_body_dir (account, folder);
        folder.unread = 0;
        folder.total = 0;
        folder.server_total = 0;
        folder.server_unread = 0;
        Utils.sync_log (
            "graph empty “%s” — purged %u, wiped %u body file(s)".printf (
                folder.name, purged, wiped
            )
        );
    }

    public async void set_folder_seen (Account account, Folder folder, bool seen) throws Error {
    }

    public async void set_uids_seen (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        bool seen
    ) throws Error {
        enqueue_flag_job (account, folder, uids, true, seen);
    }

    public async void set_uids_flagged (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        bool flagged
    ) throws Error {
        enqueue_flag_job (account, folder, uids, false, flagged);
    }

    public bool folder_has_pending_flags (Account account, Folder folder) {
        return this.folders_pending_flags.contains (folder_key (account, folder));
    }

    private void enqueue_flag_job (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        bool is_seen,
        bool add
    ) {
        if (uids.length == 0)
            return;
        for (uint i = 0; i < this.flag_queue.length; i++) {
            var job = this.flag_queue[i];
            if ((job.account.source_uid ?? job.account.uid)
                    != (account.source_uid ?? account.uid)
                || job.folder.full_name != folder.full_name
                || job.is_seen != is_seen
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
            is_seen = is_seen,
            add = add,
        });
        this.folders_pending_flags.set (folder_key (account, folder), 1);
        schedule_registry_save ();
        Utils.sync_log ("graph flag deferred %s %s %u uid(s) in “%s”".printf (
            add ? "+" : "-",
            is_seen ? "seen" : "flagged",
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
        if (uids.length == 0)
            return;
        for (uint i = 0; i < this.transfer_queue.length; i++) {
            var job = this.transfer_queue[i];
            if ((job.account.source_uid ?? job.account.uid)
                    != (account.source_uid ?? account.uid)
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
        Utils.sync_log ("graph %s deferred “%s” → “%s” %u uid(s)".printf (
            delete_original ? "move" : "copy",
            from.name,
            destination.name,
            copy.length
        ));
    }

    private async void flush_pending_mutations_async () throws Error {
        if (this.flush_running)
            return;
        if (this.flag_queue.length == 0 && this.transfer_queue.length == 0)
            return;
        this.flush_running = true;
        try {
            yield flush_flag_queue_locked (null, null);
            yield flush_transfer_queue_locked (null, null);
        } finally {
            this.flush_running = false;
            if (this.flag_queue.length == 0 && this.transfer_queue.length == 0)
                clear_registry_file ();
            else
                persist_mutation_registry_now ();
        }
    }

    private async void flush_pending_mutations_scoped_async (
        Account account,
        Folder folder
    ) throws Error {
        if (this.flush_running)
            return;
        if (this.flag_queue.length == 0 && this.transfer_queue.length == 0)
            return;
        this.flush_running = true;
        try {
            yield flush_flag_queue_locked (account, folder);
            yield flush_transfer_queue_locked (account, folder);
            /* Refresh Graph totals for the open folder after scoped push. */
            try {
                yield refresh_folder_counts (account, folder, null);
            } catch (Error e) {
                warning ("GraphMailBackend post-flush counts: %s", e.message);
            }
        } finally {
            this.flush_running = false;
            if (this.flag_queue.length == 0 && this.transfer_queue.length == 0)
                clear_registry_file ();
            else
                persist_mutation_registry_now ();
        }
    }

    private static bool job_touches_folder (
        Account? scope_account,
        Folder? scope_folder,
        Account job_account,
        Folder a,
        Folder? b = null
    ) {
        if (scope_account == null || scope_folder == null)
            return true;
        var acc = scope_account.source_uid ?? scope_account.uid;
        var job_acc = job_account.source_uid ?? job_account.uid;
        if (acc != job_acc)
            return false;
        if (a.full_name == scope_folder.full_name)
            return true;
        if (b != null && b.full_name == scope_folder.full_name)
            return true;
        return false;
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

    private static string graph_registry_dir () {
        return Path.build_filename (
            Environment.get_user_data_dir (),
            "letter",
            "mutation-registry"
        );
    }

    private static string graph_registry_file () {
        return Path.build_filename (graph_registry_dir (), "pending-graph");
    }

    private void clear_registry_file () {
        var path = graph_registry_file ();
        if (!FileUtils.test (path, FileTest.IS_REGULAR))
            return;
        if (FileUtils.remove (path) == 0)
            Utils.sync_log ("graph mutation registry cleared");
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
        return id_acc.to_account ();
    }

    private async void flush_flag_queue_locked (
        Account? scope_account,
        Folder? scope_folder
    ) throws Error {
        uint i = 0;
        while (i < this.flag_queue.length) {
            var job = this.flag_queue[i];
            if (!job_touches_folder (scope_account, scope_folder, job.account, job.folder)) {
                i++;
                continue;
            }
            this.flag_queue.remove_index (i);
            Error? push_error = null;
            SourceFunc callback = flush_flag_queue_locked.callback;
            var acc = job.account;
            var uids = job.uids;
            var is_seen = job.is_seen;
            var add = job.add;
            new Thread<void*> ("letter-graph-flags", () => {
                try {
                    var client = open_client (acc);
                    for (uint u = 0; u < uids.length; u++) {
                        if (is_seen)
                            client.set_message_read_sync (uids[u], add, null);
                        else
                            client.set_message_flagged_sync (uids[u], add, null);
                    }
                } catch (Error e) {
                    push_error = e;
                }
                Idle.add (() => {
                    callback ();
                    return Source.REMOVE;
                });
                return null;
            });
            yield;
            if (push_error != null) {
                this.flag_queue.insert ((int) i, job);
                warning ("GraphMailBackend flag push: %s", push_error.message);
                break;
            }
            clear_folder_pending_flags (job.account, job.folder);
            Utils.sync_log ("graph flag flushed %s %s %u in “%s”".printf (
                add ? "+" : "-",
                is_seen ? "seen" : "flagged",
                uids.length,
                job.folder.name
            ));
            try {
                yield refresh_folder_counts (job.account, job.folder, null);
            } catch (Error e) {
            }
        }
    }

    private async void flush_transfer_queue_locked (
        Account? scope_account,
        Folder? scope_folder
    ) throws Error {
        uint i = 0;
        while (i < this.transfer_queue.length) {
            var job = this.transfer_queue[i];
            if (!job_touches_folder (
                    scope_account, scope_folder, job.account, job.from, job.destination)) {
                i++;
                continue;
            }
            this.transfer_queue.remove_index (i);
            Error? push_error = null;
            var failed = new GenericArray<string> ();
            SourceFunc callback = flush_transfer_queue_locked.callback;
            var acc = job.account;
            var dest_id = job.destination.full_name;
            var uids = job.uids;
            var delete_original = job.delete_original;
            new Thread<void*> ("letter-graph-move", () => {
                try {
                    var client = open_client (acc);
                    for (uint u = 0; u < uids.length; u++) {
                        try {
                            if (delete_original)
                                client.move_message_sync (uids[u], dest_id, null);
                            else
                                client.copy_message_sync (uids[u], dest_id, null);
                        } catch (Error e) {
                            failed.add (uids[u]);
                            push_error = e;
                        }
                    }
                } catch (Error e) {
                    push_error = e;
                    for (uint u = 0; u < uids.length; u++)
                        failed.add (uids[u]);
                }
                Idle.add (() => {
                    callback ();
                    return Source.REMOVE;
                });
                return null;
            });
            yield;
            if (failed.length > 0) {
                job.uids = failed;
                this.transfer_queue.insert ((int) i, job);
                warning ("GraphMailBackend %s push: %s".printf (
                    delete_original ? "move" : "copy",
                    push_error != null ? push_error.message : "partial failure"
                ));
                var fail_uids = new GenericArray<string> ();
                for (uint u = 0; u < failed.length; u++)
                    fail_uids.add (failed[u]);
                transfer_failed (job.account, job.from, fail_uids,
                    push_error != null ? push_error.message : _("Move failed"));
                break;
            }
            /* Keep source UIDs retired after a successful Graph move. Tip-merge
             * would otherwise resurrect the pre-move id in the source folder
             * until an until-done walk replaces the Letter index. */
            Utils.sync_log ("graph %s flushed “%s” → “%s” %u".printf (
                delete_original ? "move" : "copy",
                job.from.name,
                job.destination.name,
                uids.length
            ));
            try {
                yield refresh_folder_counts (job.account, job.from, null);
            } catch (Error e) {
            }
            try {
                yield refresh_folder_counts (job.account, job.destination, null);
            } catch (Error e) {
            }
        }
    }

    private void clear_folder_pending_flags (Account account, Folder folder) {
        var key = folder_key (account, folder);
        for (uint i = 0; i < this.flag_queue.length; i++) {
            var job = this.flag_queue[i];
            if ((job.account.source_uid ?? job.account.uid)
                    == (account.source_uid ?? account.uid)
                && job.folder.full_name == folder.full_name)
                return;
        }
        this.folders_pending_flags.remove (key);
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
        if (find_identity (account) == null || get_identity (account) == null) {
            throw new IOError.FAILED (_("This account has no sending identity."));
        }
        var to_list = LetterSmtp.MimeBuilder.parse_address_list (to);
        if (to_list.length == 0) {
            throw new IOError.INVALID_ARGUMENT (_("Add at least one recipient."));
        }
        ensure_valid_recipients (to_list);
        ensure_valid_recipients (LetterSmtp.MimeBuilder.parse_address_list (cc));
        ensure_valid_recipients (LetterSmtp.MimeBuilder.parse_address_list (bcc));
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
        var identity = get_identity (account);
        if (identity == null) {
            throw new IOError.FAILED (_("This account has no sending identity."));
        }

        /* Reply: createReply keeps Outlook conversationId (no Outlook-item MIME).
         * Forward: always sendMail — createForward still NDRs to many externals
         * even after stripping the item attachment (Graph accepts, then bounce).
         * Letter threads forwards locally via conversation_key / msgid_refs.
         * Attachments >3 MiB need createUploadSession — force draft+attach+send. */
        var message_json = build_graph_message_json (
            to, cc, bcc, subject, body, html, null, high_priority
        );
        var need_upload = attachments_need_upload_session (attachments);
        var message_json_with_att = need_upload
            ? message_json
            : build_graph_message_json (
                to, cc, bcc, subject, body, html, attachments, high_priority
            );
        var parent_uid = (reply_of != null) ? reply_of.uid : null;
        var use_create_reply = !is_forward
            && parent_uid != null
            && is_graph_message_id (parent_uid);
        var use_draft_send = use_create_reply || need_upload;
        Error? push_error = null;
        string send_via = "sendMail";
        SourceFunc callback = send_message.callback;
        var acc = account;
        var atts = attachments;
        send_starting ();
        new Thread<void*> ("letter-graph-send", () => {
            try {
                var client = open_client (acc);
                if (use_draft_send) {
                    string? draft_id = null;
                    try {
                        if (use_create_reply) {
                            draft_id = client.create_reply_draft_sync (parent_uid, false, cancellable);
                            client.clear_message_attachments_sync (draft_id, cancellable);
                            client.update_message_sync (draft_id, message_json, cancellable);
                            send_via = need_upload ? "createReply+upload" : "createReply";
                        } else {
                            draft_id = client.create_draft_sync (message_json, cancellable);
                            send_via = "draft+upload";
                        }
                        append_graph_file_attachments (client, draft_id, atts, cancellable);
                        client.send_draft_sync (draft_id, cancellable);
                    } catch (Error threaded_e) {
                        if (need_upload || !use_create_reply)
                            throw threaded_e;
                        warning (
                            "Graph createReply failed (%s) — falling back to sendMail",
                            threaded_e.message
                        );
                        if (draft_id != null && draft_id.length > 0) {
                            try {
                                client.delete_message_sync (draft_id, null);
                            } catch (Error del_e) {
                            }
                        }
                        var payload = "{\"message\":%s,\"saveToSentItems\":true}".printf (
                            message_json_with_att
                        );
                        client.send_mail_sync (payload, cancellable);
                        send_via = "sendMail-fallback";
                    }
                } else {
                    var payload = "{\"message\":%s,\"saveToSentItems\":true}".printf (
                        message_json_with_att
                    );
                    client.send_mail_sync (payload, cancellable);
                    send_via = is_forward ? "sendMail-forward" : "sendMail";
                }
            } catch (Error e) {
                push_error = e;
            }
            Idle.add (() => {
                callback ();
                return Source.REMOVE;
            });
            return null;
        });
        yield;
        send_finished ();
        if (push_error != null)
            throw push_error;

        Utils.sync_log ("graph %s ok to=%s".printf (send_via, to));

        var local_uid = "local-sent-%lld".printf (new DateTime.now_utc ().to_unix ());
        var sent = message_from_outgoing (
            local_uid, identity, to, cc, subject, body, attachments, reply_of,
            high_priority, true, true
        );
        var content = content_from_outgoing (local_uid, identity, to, cc, bcc, subject, body, html, attachments);
        this.local_outgoing_bodies.set (local_uid, content);
        try {
            var file = local_outgoing_body_file (account, local_uid);
            var parent = file.get_parent ();
            if (parent != null && !parent.query_exists (null))
                parent.make_directory_with_parents (null);
            file.replace_contents (
                content_to_cache_json (content).data,
                null, false, FileCreateFlags.PRIVATE, null, null
            );
        } catch (Error e) {
            warning ("GraphMailBackend local sent body: %s", e.message);
        }
        message_sent (account, sent);
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

        var drafts = resolve_drafts_folder (account);
        drafts_folder = drafts;

        var need_upload = attachments_need_upload_session (attachments);
        var message_json = build_graph_message_json (
            to, cc, bcc, subject, body, html,
            need_upload ? null : attachments,
            high_priority
        );

        string? server_uid = null;
        Error? push_error = null;
        SourceFunc callback = save_draft.callback;
        var acc = account;
        var replace = replace_uid;
        var atts = attachments;
        new Thread<void*> ("letter-graph-draft", () => {
            try {
                var client = open_client (acc);
                if (replace != null && replace.length > 0 && is_graph_message_id (replace)) {
                    try {
                        client.update_message_sync (replace, message_json, cancellable);
                        server_uid = replace;
                        if (need_upload) {
                            client.clear_message_attachments_sync (server_uid, cancellable);
                            append_graph_file_attachments (client, server_uid, atts, cancellable);
                        }
                    } catch (Error e) {
                        /* Stale id — create a new draft and drop the old one. */
                        server_uid = client.create_draft_sync (message_json, cancellable);
                        if (need_upload)
                            append_graph_file_attachments (client, server_uid, atts, cancellable);
                        try {
                            client.delete_message_sync (replace, null);
                        } catch (Error del_e) {
                        }
                    }
                } else {
                    server_uid = client.create_draft_sync (message_json, cancellable);
                    if (need_upload)
                        append_graph_file_attachments (client, server_uid, atts, cancellable);
                }
            } catch (Error e) {
                push_error = e;
            }
            Idle.add (() => {
                callback ();
                return Source.REMOVE;
            });
            return null;
        });
        yield;
        if (push_error != null)
            throw push_error;
        if (server_uid == null || server_uid.length == 0) {
            throw new IOError.FAILED (_("Graph did not return a draft id."));
        }

        var draft = message_from_outgoing (
            server_uid, identity, to, cc, subject, body, attachments, reply_of,
            high_priority, true, false
        );
        draft.folder_name = drafts.name;
        draft.folder_full_name = drafts.full_name;

        var content = content_from_outgoing (
            server_uid, identity, to, cc, bcc, subject, body, html, attachments
        );
        this.local_outgoing_bodies.set (server_uid, content);
        this.body_ram.set (body_key (account, drafts, server_uid), content);
        try {
            var file = body_file (account, drafts, server_uid);
            var parent = file.get_parent ();
            if (parent != null && !parent.query_exists (null))
                parent.make_directory_with_parents (null);
            file.replace_contents (
                content_to_cache_json (content).data,
                null, false, FileCreateFlags.PRIVATE, null, null
            );
        } catch (Error e) {
            warning ("GraphMailBackend draft body: %s", e.message);
        }

        if (replace != null && replace.length > 0 && replace != server_uid)
            this.local_outgoing_bodies.remove (replace);

        draft_saved (account, draft, replace_uid);
        Utils.sync_log ("graph draft saved “%s” uid=%s".printf (drafts.name, server_uid));
        return draft;
    }

    public async void reset_account_storage (Account account) throws Error {
        this.body_ram.remove_all ();
        var root = File.new_for_path (Path.build_filename (
            Environment.get_user_data_dir (),
            "letter",
            "engine",
            "graph",
            account.source_uid ?? account.uid
        ));
        if (root.query_exists (null)) {
            try {
                yield root.trash_async (Priority.DEFAULT, null);
            } catch (Error e) {
                warning ("GraphMailBackend reset: %s", e.message);
            }
        }
    }

    private LetterGraph.Client open_client (Account account) throws Error {
        this.io_lock.lock ();
        try {
            try {
                this.catalog = IdentityCatalog.load ();
            } catch (Error e) {
            }
            var id_acc = find_identity (account);
            if (id_acc == null) {
                throw new IOError.NOT_FOUND (
                    _("No Letter Identity account for Graph mail.")
                );
            }
            var token = IdentityOAuth.ensure_microsoft_graph_access_sync (id_acc);
            return new LetterGraph.Client (token);
        } finally {
            this.io_lock.unlock ();
        }
    }

    private IdentityAccount? find_identity (Account account) {
        var id = account.source_uid ?? account.uid;
        for (uint i = 0; i < this.catalog.accounts.length; i++) {
            if (this.catalog.accounts[i].id == id)
                return this.catalog.accounts[i];
        }
        return null;
    }

    private static Error not_supported (string what) {
        return new IOError.NOT_SUPPORTED (
            _("Graph engine does not support %s yet (slice 1).").printf (what)
        );
    }

    private static void ensure_valid_recipients (GenericArray<string> list) throws Error {
        for (uint i = 0; i < list.length; i++) {
            var email = LetterSmtp.MimeBuilder.extract_email (list[i]);
            if (email.index_of_char ('@') <= 0) {
                throw new IOError.INVALID_ARGUMENT (
                    _("Invalid recipient: %s").printf (list[i])
                );
            }
        }
    }

    private static bool is_graph_message_id (string? uid) {
        if (uid == null || uid.length == 0)
            return false;
        /* Graph message ids are base64url (AAMk…); folder ids are AQMk…. */
        return uid.has_prefix ("AAMk") || uid.has_prefix ("AQMk");
    }

    private Folder resolve_drafts_folder (Account account) {
        var cached = this.folder_list_cache.get (account.uid);
        if (cached != null) {
            for (uint i = 0; i < cached.length; i++) {
                if (cached[i].kind == FolderKind.DRAFTS)
                    return cached[i];
            }
        }
        return new Folder () {
            name = C_("Mail folder", "Drafts"),
            full_name = "drafts",
            flags = 0,
        };
    }

    private static string build_graph_message_json (
        string to,
        string? cc,
        string? bcc,
        string subject,
        string body,
        string? html,
        GenericArray<Attachment>? attachments,
        bool high_priority
    ) throws Error {
        var sb = new StringBuilder ();
        sb.append ("{");
        sb.append_printf (
            "\"subject\":\"%s\"",
            LetterGraph.Client.escape_json_string (subject ?? "")
        );
        var content_type = (html != null && html.strip ().length > 0) ? "HTML" : "Text";
        var content = (html != null && html.strip ().length > 0) ? html : (body ?? "");
        sb.append_printf (
            ",\"body\":{\"contentType\":\"%s\",\"content\":\"%s\"}",
            content_type,
            LetterGraph.Client.escape_json_string (content)
        );
        sb.append (",\"toRecipients\":");
        sb.append (recipients_json (to));
        if (cc != null && cc.strip ().length > 0) {
            sb.append (",\"ccRecipients\":");
            sb.append (recipients_json (cc));
        }
        if (bcc != null && bcc.strip ().length > 0) {
            sb.append (",\"bccRecipients\":");
            sb.append (recipients_json (bcc));
        }
        if (high_priority)
            sb.append (",\"importance\":\"high\"");
        if (attachments != null && attachments.length > 0) {
            sb.append (",\"attachments\":");
            sb.append (attachments_json (attachments));
        }
        sb.append ("}");
        return sb.str;
    }

    private static string recipients_json (string? raw) {
        var list = LetterSmtp.MimeBuilder.parse_address_list (raw);
        var sb = new StringBuilder ();
        sb.append ("[");
        for (uint i = 0; i < list.length; i++) {
            if (i > 0)
                sb.append (",");
            var email = LetterSmtp.MimeBuilder.extract_email (list[i]);
            var name = list[i].strip ();
            var angle = name.index_of_char ('<');
            if (angle > 0)
                name = name.substring (0, angle).strip ().replace ("\"", "");
            else
                name = "";
            sb.append ("{\"emailAddress\":{");
            if (name.length > 0) {
                sb.append_printf (
                    "\"name\":\"%s\",",
                    LetterGraph.Client.escape_json_string (name)
                );
            }
            sb.append_printf (
                "\"address\":\"%s\"}}",
                LetterGraph.Client.escape_json_string (email)
            );
        }
        sb.append ("]");
        return sb.str;
    }

    private static bool attachments_need_upload_session (
        GenericArray<Attachment>? attachments
    ) {
        if (attachments == null)
            return false;
        for (uint i = 0; i < attachments.length; i++) {
            var att = attachments[i];
            size_t size = 0;
            if (att.data != null)
                size = att.data.get_size ();
            if (size == 0 && att.size_bytes > 0)
                size = (size_t) att.size_bytes;
            if (size == 0 && att.file != null) {
                try {
                    var info = att.file.query_info (
                        FileAttribute.STANDARD_SIZE,
                        FileQueryInfoFlags.NONE,
                        null
                    );
                    size = (size_t) info.get_size ();
                } catch (Error e) {
                }
            }
            if (size > GRAPH_INLINE_ATTACHMENT_MAX)
                return true;
        }
        return false;
    }

    private static Bytes? attachment_bytes (Attachment att) throws Error {
        if (att.data != null && att.data.get_size () > 0)
            return att.data;
        if (att.file == null)
            return null;
        uint8[] contents;
        string etag;
        att.file.load_contents (null, out contents, out etag);
        if (contents.length == 0)
            return null;
        return new Bytes (contents);
    }

    private static void append_graph_file_attachments (
        LetterGraph.Client client,
        string draft_id,
        GenericArray<Attachment>? attachments,
        Cancellable? cancellable
    ) throws Error {
        if (attachments == null || attachments.length == 0)
            return;
        for (uint i = 0; i < attachments.length; i++) {
            var att = attachments[i];
            var data = attachment_bytes (att);
            if (data == null || data.get_size () == 0)
                continue;
            var name = att.filename ?? "attachment";
            var mime = (att.mime_type != null && att.mime_type.length > 0)
                ? att.mime_type : "application/octet-stream";
            if (data.get_size () > GRAPH_INLINE_ATTACHMENT_MAX) {
                client.add_file_attachment_upload_session_sync (
                    draft_id, name, mime, data, cancellable
                );
            } else {
                client.add_file_attachment_sync (draft_id, name, mime, data, cancellable);
            }
        }
    }

    private static string attachments_json (GenericArray<Attachment> attachments) throws Error {
        var sb = new StringBuilder ();
        sb.append ("[");
        bool first = true;
        for (uint i = 0; i < attachments.length; i++) {
            var att = attachments[i];
            var data = attachment_bytes (att);
            if (data == null || data.get_size () == 0)
                continue;
            if (data.get_size () > GRAPH_INLINE_ATTACHMENT_MAX) {
                throw new IOError.INVALID_ARGUMENT (
                    _("Large attachments require draft upload — internal send path error.")
                );
            }
            if (!first)
                sb.append (",");
            first = false;
            unowned uint8[] raw = data.get_data ();
            var b64 = Base64.encode (raw);
            var name = att.filename ?? "attachment";
            var mime = (att.mime_type != null && att.mime_type.length > 0)
                ? att.mime_type : "application/octet-stream";
            sb.append ("{");
            sb.append ("\"@odata.type\":\"#microsoft.graph.fileAttachment\",");
            sb.append_printf (
                "\"name\":\"%s\",",
                LetterGraph.Client.escape_json_string (name)
            );
            sb.append_printf (
                "\"contentType\":\"%s\",",
                LetterGraph.Client.escape_json_string (mime)
            );
            sb.append_printf ("\"contentBytes\":\"%s\"", b64);
            sb.append ("}");
        }
        sb.append ("]");
        return sb.str;
    }

    private static Message message_from_outgoing (
        string uid,
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
        var preview = (body ?? "").make_valid ().strip ().replace ("\n", " ");
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
            var rh = MailSession.hash_message_id_raw (reply_of.message_id);
            if (rh != 0)
                refs = { rh };
        }
        string? conv = null;
        if (reply_of != null)
            conv = graph_conversation_key (reply_of.conversation_id);
        return new Message () {
            uid = uid,
            subject = subj,
            from = from_disp,
            to = to_disp,
            cc = cc ?? "",
            to_header = to_disp.length > 0 ? to_disp : null,
            cc_header = (cc != null && cc.strip ().length > 0) ? cc.strip () : null,
            list_address = to_disp.length > 0 ? to_disp : from_disp,
            date = new DateTime.now_local ().to_unix (),
            seen = true,
            outgoing = outgoing,
            local_only = local_only,
            preview = preview.length > 0 ? preview : null,
            has_attachment = attachments != null && attachments.length > 0,
            important = high_priority,
            msgid_hash = 0,
            msgid_refs = refs,
            conversation_key = conv,
        };
    }

    private static string? graph_conversation_key (string? conversation_id) {
        if (conversation_id == null)
            return null;
        var cid = conversation_id.strip ();
        if (cid.length == 0)
            return null;
        return "cid:%s".printf (cid.casefold ());
    }

    private static MessageContent content_from_outgoing (
        string uid,
        Identity identity,
        string to,
        string? cc,
        string? bcc,
        string subject,
        string body,
        string? html,
        GenericArray<Attachment>? attachments
    ) {
        var content = new MessageContent ();
        content.uid = uid;
        content.subject = subject.strip ().length > 0 ? subject.strip () : _("(No subject)");
        content.from = (identity.name != null && identity.name.length > 0)
            ? "%s <%s>".printf (identity.name, identity.address)
            : identity.address;
        content.from_email = identity.address;
        content.to = to ?? "";
        content.cc = cc;
        content.bcc = bcc;
        content.date = new DateTime.now_local ().to_unix ();
        content.plain_text = body ?? "";
        if (html != null && html.strip ().length > 0) {
            content.html = html;
            content.rich_html = true;
        } else {
            content.html = MessageContent.text_to_html (body ?? "");
            content.rich_html = false;
        }
        if (attachments != null && attachments.length > 0) {
            content.attachments = new GenericArray<Attachment> ();
            for (uint i = 0; i < attachments.length; i++)
                content.attachments.add (attachments[i]);
        }
        return content;
    }

    private static File local_outgoing_body_file (Account account, string uid) {
        return File.new_for_path (Path.build_filename (
            Environment.get_user_data_dir (),
            "letter",
            "engine",
            "graph",
            account.source_uid ?? account.uid,
            "outgoing",
            uid + ".json"
        ));
    }

    private uint wipe_folder_body_dir (Account account, Folder folder) {
        var dir = body_file (account, folder, "_").get_parent ();
        if (dir == null || !dir.query_exists (null))
            return 0;
        uint removed = 0;
        try {
            var enumerator = dir.enumerate_children (
                "standard::name,standard::type",
                FileQueryInfoFlags.NONE,
                null
            );
            FileInfo? info;
            while ((info = enumerator.next_file (null)) != null) {
                var name = info.get_name ();
                if (name == null)
                    continue;
                try {
                    var child = dir.get_child (name);
                    if (info.get_file_type () == FileType.DIRECTORY) {
                        wipe_directory_children (child);
                        child.delete (null);
                    } else {
                        child.delete (null);
                    }
                    if (name.has_suffix (".json")) {
                        var uid = name.substring (0, name.length - 5);
                        var key = body_key (account, folder, uid);
                        this.body_ram.remove (key);
                        this.body_ram_touched.remove (key);
                    }
                    removed++;
                } catch (Error e) {
                }
            }
        } catch (Error e) {
            warning ("GraphMailBackend wipe bodies “%s”: %s", folder.name, e.message);
        }
        return removed;
    }

    private static string folder_key (Account account, Folder folder) {
        return "%s\n%s".printf (account.uid, folder.full_name);
    }

    private static string body_key (Account account, Folder folder, string uid) {
        return "%s\n%s\n%s".printf (account.source_uid ?? account.uid, folder.full_name, uid);
    }

    private static File body_file (Account account, Folder folder, string uid) {
        var safe_folder = folder.full_name.replace ("/", "_");
        return File.new_for_path (Path.build_filename (
            Environment.get_user_data_dir (),
            "letter",
            "engine",
            "graph",
            account.source_uid ?? account.uid,
            safe_folder,
            uid + ".json"
        ));
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
                "graph body index search “%s” %s → %u of %u indexed".printf (
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
        }
        text = replace_literal_graph (text, "&nbsp;", " ");
        text = replace_literal_graph (text, "&amp;", "&");
        text = replace_literal_graph (text, "&lt;", "<");
        text = replace_literal_graph (text, "&gt;", ">");
        text = replace_literal_graph (text, "&quot;", "\"");
        return text;
    }

    private static string replace_literal_graph (string input, string from, string to) {
        if (from.length == 0 || !input.contains (from))
            return input;
        var sb = new StringBuilder ();
        int start = 0;
        int idx;
        while ((idx = input.index_of (from, start)) >= 0) {
            sb.append (input.substring (start, idx - start));
            sb.append (to);
            start = idx + from.length;
        }
        sb.append (input.substring (start));
        return sb.str;
    }

    private static int64 parse_graph_datetime (string? iso) {
        if (iso == null || iso.length == 0)
            return 0;
        try {
            var dt = new DateTime.from_iso8601 (iso, null);
            if (dt != null)
                return dt.to_unix ();
        } catch (Error e) {
        }
        return 0;
    }

    private static MessageContent content_from_graph_body (LetterGraph.MessageBody body) {
        var is_html = (body.content_type ?? "").down ().contains ("html");
        string html;
        string? plain;
        if (is_html) {
            html = utf8_or_valid (body.content);
            plain = null;
        } else {
            plain = utf8_or_valid (body.content);
            html = MessageContent.text_to_html (plain);
        }
        var to_raw = utf8_or_valid (body.to) ?? "";
        var cc_raw = utf8_or_valid (body.cc);
        return new MessageContent () {
            uid = body.id,
            subject = utf8_or_valid (body.subject) ?? _("(No subject)"),
            from = utf8_or_valid (body.from) ?? _("Unknown sender"),
            from_email = Utils.email_from_header (body.from),
            to = to_raw,
            cc = cc_raw,
            date = parse_graph_datetime (body.received),
            html = html,
            plain_text = plain,
            rich_html = is_html,
            has_remote_images = Utils.html_has_remote_images (html),
            message_id = body.internet_message_id,
            conversation_id = body.conversation_id,
            to_recipients = Utils.parse_recipient_list (to_raw),
            cc_recipients = Utils.parse_recipient_list (cc_raw),
            bcc_recipients = new GenericArray<Recipient> (),
        };
    }

    /** Spam bodies sometimes ship invalid UTF-8; Json.Builder / WebKit choke. */
    private static string utf8_or_valid (string? s) {
        if (s == null || s.length == 0)
            return "";
        if (s.validate ())
            return s;
        return s.make_valid ();
    }

    private static string content_to_cache_json (MessageContent content) {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("uid");
        builder.add_string_value (content.uid ?? "");
        builder.set_member_name ("subject");
        builder.add_string_value (content.subject ?? "");
        builder.set_member_name ("from");
        builder.add_string_value (content.from ?? "");
        builder.set_member_name ("to");
        builder.add_string_value (content.to ?? "");
        if (content.cc != null) {
            builder.set_member_name ("cc");
            builder.add_string_value (content.cc);
        }
        builder.set_member_name ("date");
        builder.add_int_value (content.date);
        builder.set_member_name ("html");
        builder.add_string_value (content.html ?? "");
        if (content.plain_text != null) {
            builder.set_member_name ("plain_text");
            builder.add_string_value (content.plain_text);
        }
        builder.set_member_name ("rich_html");
        builder.add_boolean_value (content.rich_html);
        builder.set_member_name ("has_remote_images");
        builder.add_boolean_value (content.has_remote_images);
        if (content.message_id != null && content.message_id.length > 0) {
            builder.set_member_name ("message_id");
            builder.add_string_value (content.message_id);
        }
        if (content.conversation_id != null && content.conversation_id.length > 0) {
            builder.set_member_name ("conversation_id");
            builder.add_string_value (content.conversation_id);
        }
        if (content.attachments != null && content.attachments.length > 0) {
            builder.set_member_name ("attachments");
            builder.begin_array ();
            for (uint i = 0; i < content.attachments.length; i++) {
                var att = content.attachments[i];
                builder.begin_object ();
                builder.set_member_name ("filename");
                builder.add_string_value (att.filename ?? "attachment");
                builder.set_member_name ("mime_type");
                builder.add_string_value (att.mime_type ?? "application/octet-stream");
                builder.set_member_name ("size");
                builder.add_int_value (att.resolved_size_bytes ());
                builder.set_member_name ("relpath");
                builder.add_string_value (attachment_relpath (i, att.filename));
                builder.set_member_name ("inline_part");
                builder.add_boolean_value (att.inline_part);
                if (att.content_id != null && att.content_id.length > 0) {
                    builder.set_member_name ("content_id");
                    builder.add_string_value (att.content_id);
                }
                builder.end_object ();
            }
            builder.end_array ();
        }
        if (content.inline_images != null && content.inline_images.length > 0) {
            builder.set_member_name ("inline_images");
            builder.begin_array ();
            for (uint i = 0; i < content.inline_images.length; i++) {
                var img = content.inline_images[i];
                builder.begin_object ();
                builder.set_member_name ("cid");
                builder.add_string_value (img.cid ?? "");
                builder.set_member_name ("mime_type");
                builder.add_string_value (img.mime_type ?? "image/png");
                builder.set_member_name ("relpath");
                builder.add_string_value (inline_relpath (i, img.cid));
                builder.end_object ();
            }
            builder.end_array ();
        }
        builder.end_object ();
        var gen = new Json.Generator ();
        gen.set_root (builder.get_root ());
        return gen.to_data (null);
    }

    private static MessageContent? content_from_cache_json (uint8[] data) {
        if (data.length == 0)
            return null;
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((string) data, data.length);
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                return null;
            var o = root.get_object ();
            var to_raw = o.has_member ("to") ? o.get_string_member ("to") : "";
            var cc_raw = o.has_member ("cc") ? o.get_string_member ("cc") : null;
            var html = o.has_member ("html") ? o.get_string_member ("html") : "";
            var content = new MessageContent () {
                uid = o.has_member ("uid") ? o.get_string_member ("uid") : "",
                subject = o.has_member ("subject") ? o.get_string_member ("subject") : _("(No subject)"),
                from = o.has_member ("from") ? o.get_string_member ("from") : _("Unknown sender"),
                from_email = Utils.email_from_header (
                    o.has_member ("from") ? o.get_string_member ("from") : null
                ),
                to = to_raw ?? "",
                cc = cc_raw,
                date = o.has_member ("date") ? (int64) o.get_int_member ("date") : 0,
                html = html,
                plain_text = o.has_member ("plain_text") ? o.get_string_member ("plain_text") : null,
                rich_html = o.has_member ("rich_html") && o.get_boolean_member ("rich_html"),
                has_remote_images = o.has_member ("has_remote_images")
                    ? o.get_boolean_member ("has_remote_images")
                    : Utils.html_has_remote_images (html ?? ""),
                message_id = o.has_member ("message_id") ? o.get_string_member ("message_id") : null,
                conversation_id = o.has_member ("conversation_id")
                    ? o.get_string_member ("conversation_id") : null,
                to_recipients = Utils.parse_recipient_list (to_raw),
                cc_recipients = Utils.parse_recipient_list (cc_raw),
                bcc_recipients = new GenericArray<Recipient> (),
            };
            if (o.has_member ("attachments")
                && o.get_member ("attachments").get_node_type () == Json.NodeType.ARRAY) {
                var atts = new GenericArray<Attachment> ();
                foreach (var node in o.get_array_member ("attachments").get_elements ()) {
                    var ao = node.get_object ();
                    atts.add (new Attachment () {
                        filename = ao.has_member ("filename")
                            ? ao.get_string_member ("filename") : "attachment",
                        mime_type = ao.has_member ("mime_type")
                            ? ao.get_string_member ("mime_type") : "application/octet-stream",
                        size_bytes = ao.has_member ("size") ? ao.get_int_member ("size") : -1,
                        inline_part = ao.has_member ("inline_part")
                            && ao.get_boolean_member ("inline_part"),
                        content_id = ao.has_member ("content_id")
                            ? ao.get_string_member ("content_id") : null,
                        data = new Bytes ({}),
                    });
                    /* relpath restored in attach_parts_from_disk via index. */
                    atts[atts.length - 1].set_data (
                        "graph-relpath",
                        ao.has_member ("relpath") ? ao.get_string_member ("relpath") : null
                    );
                }
                content.attachments = atts;
            }
            if (o.has_member ("inline_images")
                && o.get_member ("inline_images").get_node_type () == Json.NodeType.ARRAY) {
                var images = new GenericArray<InlineImage> ();
                foreach (var node in o.get_array_member ("inline_images").get_elements ()) {
                    var io = node.get_object ();
                    var img = new InlineImage () {
                        cid = io.has_member ("cid") ? io.get_string_member ("cid") : "",
                        mime_type = io.has_member ("mime_type")
                            ? io.get_string_member ("mime_type") : "image/png",
                        data = new Bytes ({}),
                    };
                    img.set_data (
                        "graph-relpath",
                        io.has_member ("relpath") ? io.get_string_member ("relpath") : null
                    );
                    images.add (img);
                }
                content.inline_images = images;
            }
            return content;
        } catch (Error e) {
            return null;
        }
    }

    private void remember_body_ram (Account account, Folder folder, string uid, MessageContent content) {
        var key = body_key (account, folder, uid);
        this.body_ram.set (key, content);
        touch_body_ram (key);
        pin_body_ram (key);
    }

    private void touch_body_ram (string key) {
        this.body_ram_touched.set (key, get_monotonic_time ());
    }

    private void pin_body_ram (string key) {
        this.pinned_body_key = key;
        touch_body_ram (key);
    }

    private void flush_body_ram_unpinned () {
        var keys = new GenericArray<string> ();
        this.body_ram.foreach ((key, content) => {
            if (this.pinned_body_key == null || key != this.pinned_body_key)
                keys.add (key);
        });
        for (uint i = 0; i < keys.length; i++) {
            this.body_ram.remove (keys[i]);
            this.body_ram_touched.remove (keys[i]);
        }
    }

    private void sweep_body_ram_ttl () {
        var now = get_monotonic_time ();
        var keys = new GenericArray<string> ();
        this.body_ram.foreach ((key, content) => {
            if (this.pinned_body_key != null && key == this.pinned_body_key)
                return;
            var t = this.body_ram_touched.get (key);
            var touched = t != null ? t : (int64) 0;
            if (now - touched >= BODY_RAM_TTL_US)
                keys.add (key);
        });
        for (uint i = 0; i < keys.length; i++) {
            this.body_ram.remove (keys[i]);
            this.body_ram_touched.remove (keys[i]);
        }
        if (keys.length > 0) {
            Utils.sync_log (
                "graph body-ram ttl: dropped %u (pin kept, disk intact)".printf (keys.length)
            );
        }
    }

    private static string attachment_relpath (uint index, string? filename) {
        var safe = Path.get_basename (filename ?? "attachment");
        safe = safe.replace ("/", "-").replace ("\\", "-");
        if (safe.length == 0)
            safe = "attachment";
        return "%u-%s".printf (index, safe);
    }

    private static string inline_relpath (uint index, string? cid) {
        var safe = (cid ?? "img").replace ("/", "-").replace ("\\", "-").replace ("@", "_");
        if (safe.length == 0)
            safe = "img";
        if (safe.length > 80)
            safe = safe.substring (0, 80);
        return "inline-%u-%s.bin".printf (index, safe);
    }

    private static File attachment_dir (Account account, Folder folder, string uid) {
        return File.new_for_path (body_file (account, folder, uid).get_path () + ".att");
    }

    private void persist_attachment_sidecars (
        Account account,
        Folder folder,
        string uid,
        MessageContent content
    ) {
        var dir = attachment_dir (account, folder, uid);
        try {
            if (!dir.query_exists (null))
                dir.make_directory_with_parents (null);
        } catch (Error e) {
            warning ("GraphMailBackend att dir: %s", e.message);
            return;
        }

        if (content.attachments != null) {
            for (uint i = 0; i < content.attachments.length; i++) {
                var att = content.attachments[i];
                if (att.data == null || att.data.get_size () == 0)
                    continue;
                var rel = attachment_relpath (i, att.filename);
                var dest = dir.get_child (rel);
                try {
                    string? etag;
                    dest.replace_contents (
                        att.data.get_data (),
                        null,
                        false,
                        FileCreateFlags.PRIVATE,
                        out etag
                    );
                    att.file = dest;
                    att.size_bytes = (int64) att.data.get_size ();
                    att.set_data ("graph-relpath", rel);
                } catch (Error e) {
                    warning ("GraphMailBackend write att “%s”: %s", rel, e.message);
                }
            }
        }

        if (content.inline_images != null) {
            for (uint i = 0; i < content.inline_images.length; i++) {
                var img = content.inline_images[i];
                if (img.data == null || img.data.get_size () == 0)
                    continue;
                var rel = inline_relpath (i, img.cid);
                var dest = dir.get_child (rel);
                try {
                    string? etag;
                    dest.replace_contents (
                        img.data.get_data (),
                        null,
                        false,
                        FileCreateFlags.PRIVATE,
                        out etag
                    );
                    img.set_data ("graph-relpath", rel);
                } catch (Error e) {
                    warning ("GraphMailBackend write inline “%s”: %s", rel, e.message);
                }
            }
        }
    }

    private static void drop_attachment_bytes_after_disk (MessageContent content) {
        if (content.attachments != null) {
            for (uint i = 0; i < content.attachments.length; i++) {
                var att = content.attachments[i];
                if (att.file != null && att.file.query_exists (null))
                    att.data = new Bytes ({});
            }
        }
        /* Inline images stay in RAM while published to letterimg:; bytes also
         * on disk for rehydrate after TTL. Keep data until publish. */
    }

    private void attach_parts_from_disk (
        Account account,
        Folder folder,
        string uid,
        MessageContent content
    ) {
        var dir = attachment_dir (account, folder, uid);
        if (!dir.query_exists (null))
            return;

        if (content.attachments != null) {
            for (uint i = 0; i < content.attachments.length; i++) {
                var att = content.attachments[i];
                var rel = att.get_data<string> ("graph-relpath");
                if (rel == null || rel.length == 0)
                    rel = attachment_relpath (i, att.filename);
                var file = dir.get_child (rel);
                if (file.query_exists (null)) {
                    att.file = file;
                    if (att.size_bytes <= 0) {
                        try {
                            att.size_bytes = (int64) file.query_info (
                                FileAttribute.STANDARD_SIZE,
                                FileQueryInfoFlags.NONE,
                                null
                            ).get_size ();
                        } catch (Error e) {
                        }
                    }
                }
            }
        }

        if (content.inline_images != null) {
            for (uint i = 0; i < content.inline_images.length; i++) {
                var img = content.inline_images[i];
                if (img.data != null && img.data.get_size () > 0)
                    continue;
                var rel = img.get_data<string> ("graph-relpath");
                if (rel == null || rel.length == 0)
                    rel = inline_relpath (i, img.cid);
                var file = dir.get_child (rel);
                if (!file.query_exists (null))
                    continue;
                try {
                    uint8[] bytes;
                    string etag;
                    file.load_contents (null, out bytes, out etag);
                    img.data = new Bytes (bytes);
                } catch (Error e) {
                    warning ("GraphMailBackend load inline “%s”: %s", rel, e.message);
                }
            }
        }
    }

    private bool graph_parts_complete_on_disk (
        Account account,
        Folder folder,
        string uid,
        MessageContent content
    ) {
        var dir = attachment_dir (account, folder, uid);
        if (content.attachments != null && content.attachments.length > 0) {
            if (!dir.query_exists (null))
                return false;
            for (uint i = 0; i < content.attachments.length; i++) {
                var att = content.attachments[i];
                var rel = att.get_data<string> ("graph-relpath");
                if (rel == null || rel.length == 0)
                    rel = attachment_relpath (i, att.filename);
                if (!dir.get_child (rel).query_exists (null))
                    return false;
            }
            return true;
        }
        /* No attachment metadata yet — incomplete unless we know there are none. */
        return false;
    }

    private static void apply_inline_rewrite (MessageContent content) {
        if (content.html == null || content.html.length == 0)
            return;
        if (content.inline_images != null && content.inline_images.length > 0) {
            if (content.inline_token == 0)
                content.inline_token = InlineImagePages.reserve ();
            content.html = rewrite_graph_cids (
                content.html,
                content.inline_images,
                content.inline_token
            );
            InlineImagePages.publish (content);
        }
        content.has_remote_images = Utils.html_has_remote_images (content.html);
    }

    private static string rewrite_graph_cids (
        string html,
        GenericArray<InlineImage> images,
        uint64 token
    ) {
        if (token == 0 || images.length == 0)
            return html;
        var done = new bool[images.length];
        var result = html;
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
            result = Utils.replace_literal (result, "cid:" + cid, uri);
            result = Utils.replace_literal (result, "CID:" + cid, uri);
            var unescaped = Uri.unescape_string (cid);
            if (unescaped != null && unescaped.length > 0 && unescaped != cid) {
                result = Utils.replace_literal (result, "cid:" + unescaped, uri);
                result = Utils.replace_literal (result, "CID:" + unescaped, uri);
            }
        }
        return result;
    }

    /** Drop body JSON + .att/ for messages older than body-cache-days. */
    public uint prune_stale_bodies (
        Account account,
        Folder folder,
        GenericArray<Message> listed,
        int days
    ) {
        if (days <= 0 || listed.length == 0)
            return 0;
        var cutoff = new DateTime.now_local ().add_days (-days).to_unix ();
        uint removed = 0;
        for (uint i = 0; i < listed.length; i++) {
            var message = listed[i];
            if (message.date <= 0 || message.date >= cutoff)
                continue;
            if (drop_body_files (account, folder, message.uid))
                removed++;
        }
        if (removed > 0) {
            Utils.sync_log (
                "graph prune “%s” removed %u bodies older than %d days".printf (
                    folder.name, removed, days
                )
            );
        }
        return removed;
    }

    private bool drop_body_files (Account account, Folder folder, string uid) {
        var key = body_key (account, folder, uid);
        this.body_ram.remove (key);
        this.body_ram_touched.remove (key);
        if (this.pinned_body_key == key)
            this.pinned_body_key = null;
        bool any = false;
        try {
            var file = body_file (account, folder, uid);
            if (file.query_exists (null)) {
                file.delete (null);
                any = true;
            }
        } catch (Error e) {
        }
        try {
            var dir = attachment_dir (account, folder, uid);
            if (dir.query_exists (null)) {
                wipe_directory_children (dir);
                try {
                    dir.delete (null);
                } catch (Error e2) {
                }
                any = true;
            }
        } catch (Error e) {
        }
        return any;
    }

    private static void wipe_directory_children (File dir) {
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
                } catch (Error e) {
                }
            }
        } catch (Error e) {
        }
    }
}
