private class Mail.FolderWatch : Object {
    public Camel.Folder? camel_folder;
    public ulong changed_id;
    public string account_key;
    public string folder_name;
    public uint idle;
}

public class Mail.MailSession : Camel.Session {
    public E.SourceRegistry registry { get; construct; }

    private E.CredentialsPrompter prompter;
    private Camel.Service? authenticating_service;
    private string? authenticating_mechanism;
    private HashTable<string, MessageContent> body_cache;
    private GenericArray<FlagFlushJob> flag_flush_queue;
    private HashTable<string, FlagFlushJob> flag_flush_latest;
    private bool flag_flush_running;
    private GenericArray<TransferFlushJob> transfer_flush_queue;
    private TransferFlushJob? transfer_flush_current;
    private uint transfer_flush_done;
    private HashTable<string, uint> transfer_pending;
    private bool transfer_flush_running;
    private bool flush_force;
    /* Active move Graph call — cancelled when send preempts the flush. */
    private Cancellable? transfer_op_cancellable;
    /* Active SEEN/flag synchronize — cancelled when send (or other high
     * Camel work) needs the lock during a bulk mark-all push. */
    private Cancellable? flag_op_cancellable;
    private HashTable<string, FolderWatch> folder_watches;
    private HashTable<string, int> prefetch_cursor;
    /* M365 accounts whose Camel folder-tree already has TYPE_TRASH/JUNK. */
    private HashTable<string, bool> m365_folder_types_ok;
    private bool camel_busy;
    private int high_refresh_waiters;
    /* Outbound send must preempt archive/move flush — open-body must not. */
    private int send_waiters;
    /* Bumped when a priority waiter steals a stuck Camel lock so the old
     * holder's leave_camel does not clear the new owner's busy flag. */
    private uint camel_epoch;
    private uint camel_owner_epoch;
    private uint mutation_registry_save_source;
    private bool mutation_registry_loaded;

    public delegate void QueuedMoveHideFunc (Account account, Folder from, string uid);

    public const uint PREFETCH_NETWORK_CHUNK = 12;

    public bool header_sync_busy {
        get {
            return this.camel_busy;
        }
    }

    public bool priority_camel_waiting {
        get {
            return this.high_refresh_waiters > 0;
        }
    }

    public signal void folder_changed (string account_key, string folder_name);
    public signal void send_starting ();
    public signal void send_finished ();
    public signal void message_sent (Account account, Message? sent);
    public signal void draft_saved (Account account, Message? draft, string? replaced_uid);
    public signal void draft_removed (Account account, Folder folder, string uid);
    public signal void transfer_failed (Account account, Folder from, GenericArray<string> uids, string error);

    public MailSession (E.SourceRegistry registry) {
        var data = Path.build_filename (Environment.get_user_data_dir (), "letter", "mail");
        var cache = Path.build_filename (Environment.get_user_cache_dir (), "letter", "mail");

        try {
            File.new_for_path (data).make_directory_with_parents ();
        } catch (Error e) {
            if (!(e is IOError.EXISTS))
                warning ("Could not create mail data dir: %s", e.message);
        }

        try {
            File.new_for_path (cache).make_directory_with_parents ();
        } catch (Error e) {
            if (!(e is IOError.EXISTS))
                warning ("Could not create mail cache dir: %s", e.message);
        }

        Object (
            registry: registry,
            user_data_dir: data,
            user_cache_dir: cache,
            online: true
        );
    }

    construct {
        this.prompter = new E.CredentialsPrompter (this.registry);
        this.prompter.auto_prompt = false;
        this.prompter.get_dialog_parent.connect (on_dialog_parent);
        this.body_cache = new HashTable<string, MessageContent> (str_hash, str_equal);
        this.flag_flush_queue = new GenericArray<FlagFlushJob> ();
        this.flag_flush_latest = new HashTable<string, FlagFlushJob> (str_hash, str_equal);
        this.transfer_flush_queue = new GenericArray<TransferFlushJob> ();
        this.transfer_pending = new HashTable<string, uint> (str_hash, str_equal);
        this.folder_watches = new HashTable<string, FolderWatch> (str_hash, str_equal);
        this.prefetch_cursor = new HashTable<string, int> (str_hash, str_equal);
        this.m365_folder_types_ok = new HashTable<string, bool> (str_hash, str_equal);
    }

    public override void dispose () {
        unwatch_all_folders ();
        this.authenticating_service = null;
        base.dispose ();
    }

    /* camel_filter_driver_new() is transfer-full. Declared unowned so Vala
     * does not drop the ref; Camel.Folder unrefs the driver after filtering. */
    [CCode (cname = "camel_filter_driver_new")]
    private static extern unowned Camel.FilterDriver create_filter_driver (Camel.Session session);

    public override unowned Camel.FilterDriver get_filter_driver (string type, Camel.Folder? for_folder) throws Error {
        /* Camel.Folder unrefs the driver when the filter job finishes, even
         * though GI marks this vfunc transfer-none. Evolution returns a new
         * driver each call. Sharing one instance UAF's after the first job:
         * camel_filter_driver_log_info() then SEGV's on driver->priv. */
        return create_filter_driver (this);
    }

    private unowned Gtk.Window? on_dialog_parent () {
        var app = GLib.Application.get_default () as Gtk.Application;
        return app != null ? app.get_active_window () : null;
    }

    public override bool get_oauth2_access_token_sync (
        Camel.Service service,
        out string? out_access_token,
        out int out_expires_in,
        Cancellable? cancellable = null
    ) throws Error {
        out_access_token = null;
        out_expires_in = 0;

        var source = this.registry.ref_source (service.get_uid ());
        if (source == null) {
            throw new Camel.ServiceError.CANT_AUTHENTICATE (
                _("No data source found for UID “%s”").printf (service.get_uid ())
            );
        }

        var cred_source = this.registry.find_extension (source, E.SOURCE_EXTENSION_COLLECTION);
        if (cred_source != null && !E.util_can_use_collection_as_credential_source (cred_source, source))
            cred_source = null;

        var token_source = cred_source ?? source;
        try {
            return token_source.get_oauth2_access_token_sync (
                cancellable, out out_access_token, out out_expires_in
            );
        } catch (Error e) {
            /* E.OAuth2ServiceError is only in the Vala bindings since EDS 3.60.
             * Ubuntu and other distros may still ship 3.56 — match the quark. */
            if (e.domain.to_string () == "e-oauth2-service-error-quark")
                throw new Camel.ServiceError.CANT_AUTHENTICATE (e.message);

            throw e;
        }
    }

    public override bool authenticate_sync (
        Camel.Service service,
        string? mechanism,
        Cancellable? cancellable = null
    ) throws Error {
        /* Do not chain up: Camel's default method rejects non-SASL
         * mechanisms such as Microsoft365 / Graph. */
        if (mechanism == "none")
            mechanism = null;

        unowned Camel.ServiceAuthType? authtype = null;
        if (mechanism != null)
            authtype = Camel.Sasl.authtype (mechanism);

        if (authtype != null && !authtype.need_password) {
            var result = service.authenticate_sync (mechanism, cancellable);
            if (result == Camel.AuthenticationResult.ACCEPTED)
                return true;

            if (this.registry.get_oauth2_services ().is_oauth2_alias (mechanism))
                return prompt_credentials (service, mechanism, cancellable);

            throw new Camel.ServiceError.CANT_AUTHENTICATE (
                _("%s authentication failed").printf (mechanism)
            );
        }

        try {
            var result = service.authenticate_sync (mechanism, cancellable);
            if (result == Camel.AuthenticationResult.ACCEPTED)
                return true;
        } catch (Error e) {
            if (e is IOError.CANCELLED)
                throw e;

            debug ("Service authenticate for %s (%s): %s", service.get_uid (), mechanism ?? "default", e.message);
        }

        return prompt_credentials (service, mechanism, cancellable);
    }

    private bool prompt_credentials (
        Camel.Service service,
        string? mechanism,
        Cancellable? cancellable
    ) throws Error {
        var source = this.registry.ref_source (service.get_uid ());
        if (source == null) {
            throw new Camel.ServiceError.CANT_AUTHENTICATE (
                _("No data source found for UID “%s”").printf (service.get_uid ())
            );
        }

        this.authenticating_service = service;
        this.authenticating_mechanism = mechanism;

        try {
            var flags = E.CredentialsPrompterPromptFlags.ALLOW_SOURCE_SAVE
                | E.CredentialsPrompterPromptFlags.ALLOW_STORED_CREDENTIALS;
            return this.prompter.loop_prompt_sync (source, flags, try_credentials, cancellable);
        } finally {
            this.authenticating_service = null;
            this.authenticating_mechanism = null;
        }
    }

    private bool try_credentials (
        E.CredentialsPrompter cred_prompter,
        E.Source cred_source,
        E.NamedParameters credentials,
        out bool authenticated,
        Cancellable? cancellable
    ) throws Error {
        authenticated = false;

        var service = this.authenticating_service;
        if (service == null)
            return false;

        string? credential_name = null;
        if (cred_source.has_extension (E.SOURCE_EXTENSION_AUTHENTICATION)) {
            var auth = (E.SourceAuthentication) cred_source.get_extension (E.SOURCE_EXTENSION_AUTHENTICATION);
            credential_name = auth.dup_credential_name ();
            if (credential_name != null && credential_name.length == 0)
                credential_name = null;
        }

        var password = credentials.get (credential_name ?? E.SOURCE_CREDENTIAL_PASSWORD);
        if (password != null)
            service.set_password (password);

        var result = service.authenticate_sync (this.authenticating_mechanism, cancellable);
        authenticated = result == Camel.AuthenticationResult.ACCEPTED;

        if (authenticated) {
            var stored_source = cred_prompter.provider.ref_credentials_source (cred_source);
            if (stored_source != null)
                stored_source.invoke_authenticate_sync (credentials, cancellable);
        }

        return result == Camel.AuthenticationResult.REJECTED;
    }

    public override string get_password (
        Camel.Service service,
        string prompt,
        string item,
        uint32 flags
    ) throws Error {
        debug ("Password prompt for %s (%s, flags=%u): %s", service.get_uid (), item, flags, prompt);
        throw new IOError.NOT_SUPPORTED (
            _("Password prompts are not implemented yet. Add the account in GNOME Online Accounts.")
        );
    }

    public async Camel.Store open_store (Account account, Cancellable? cancellable = null, bool online = true) throws Error {
        if (account.kind == AccountKind.LOCAL) {
            throw new IOError.NOT_SUPPORTED (
                _("This built-in local account is not used. Choose an online account.")
            );
        }

        if (account.source_uid == null) {
            throw new IOError.NOT_FOUND (
                _("This account is not yet available to Evolution Data Server.")
            );
        }

        var source = this.registry.ref_source (account.source_uid);
        if (source == null)
            throw new IOError.NOT_FOUND (_("Mail source “%s” was not found.").printf (account.source_uid));

        var mail_account = (E.SourceMailAccount) source.get_extension (E.SOURCE_EXTENSION_MAIL_ACCOUNT);
        var protocol = mail_account.get_backend_name ();
        if (protocol == null || protocol.length == 0)
            throw new IOError.FAILED (_("The account has no mail backend."));

        var service = ref_service (account.source_uid);
        if (service == null) {
            service = add_service (account.source_uid, protocol, Camel.ProviderType.STORE);
            source.camel_configure_service (service);
        }

        ensure_service_user (service, account, source);

        var offline = service as Camel.OfflineStore;
        if (online) {
            if (offline != null) {
                if (!offline.get_online ())
                    yield offline.set_online (true, Priority.DEFAULT, cancellable);
            } else if (service.get_connection_status () != Camel.ServiceConnectionStatus.CONNECTED) {
                yield service.connect (Priority.DEFAULT, cancellable);
            }
        }

        return (Camel.Store) service;
    }

    public async GenericArray<Folder> list_folders (Account account, Cancellable? cancellable = null, bool refresh = true) throws Error {
        if (account.kind == AccountKind.LOCAL)
            return new GenericArray<Folder> ();

        var go_online = refresh && account.has_mail;
        var store = yield open_store (account, cancellable, go_online);
        var flags = Camel.StoreGetFolderInfoFlags.RECURSIVE
            | Camel.StoreGetFolderInfoFlags.SUBSCRIBED
            | Camel.StoreGetFolderInfoFlags.NO_VIRTUAL;
        if (go_online)
            flags |= Camel.StoreGetFolderInfoFlags.REFRESH;

        var t0 = Utils.sync_tick ();
        if (go_online)
            yield enter_camel (false);
        Camel.FolderInfo? info = null;
        try {
            info = yield store.get_folder_info (
                null,
                flags,
                go_online ? Priority.DEFAULT : Priority.LOW,
                cancellable
            );
        } finally {
            if (go_online)
                leave_camel (false);
        }

        var folders = new GenericArray<Folder> ();
        var roots = nodes_from_info (info);
        reshape_gmail_tree (roots);
        sort_folder_nodes (roots);
        flatten_folder_nodes (roots, 0, folders, false, false);
        Utils.sync_log ("Camel get_folder_info refresh=%s %s → %u folders".printf (
            refresh.to_string (),
            Utils.sync_ms (t0),
            folders.length
        ));
        if (folders.length == 0)
            warning ("Account %s connected but published no folders", account.source_uid);
        return folders;
    }

    private class FolderNode {
        public Folder folder;
        public GenericArray<FolderNode> children = new GenericArray<FolderNode> ();
    }

    private class FlagFlushJob {
        public Account account;
        public Folder folder;
        public GenericArray<string> uids;
        /* True → Camel.Folder.synchronize(expunge=true): purge \Deleted (IMAP
         * Empty Trash / hard-delete). False → flag upload only (SEEN/FLAGGED). */
        public bool expunge;
    }

    /* Graph accepts multi-UID moves; flush starts small and grows toward
     * DEFAULT after clean successes (same for Archive as for Trash/custom). */
    private const uint TRANSFER_CHUNK_DEFAULT = 25;
    private const uint TRANSFER_CHUNK_START = 1;
    private const uint TRANSFER_CHUNK_MIN = 1;
    /* Small destinations (Trash) usually finish in seconds; large ones
     * (Archive / big custom folders) often need longer on Graph. */
    private const uint TRANSFER_CHUNK_TIMEOUT_SECS = 90;
    private const uint TRANSFER_CHUNK_TIMEOUT_HEAVY_SECS = 180;
    private const uint TRANSFER_DEST_PROBE_SECS = 12;

    private class TransferFlushJob {
        public Account account;
        public Folder from;
        public Folder destination;
        public GenericArray<string> uids;
        public GenericArray<Message>? messages;
        public bool delete_original;
        public uint stall_rounds;
        public uint chunk_size;
        /* Non-zero: skip until Utils.sync_tick() passes this (heavy park). */
        public int64 parked_until;
        public uint park_count;
    }

    /* Archive/Junk destinations — used for longer Graph timeout and priority
     * ordering only. Moves are not throttled to one UID or parked on success. */
    private static bool folder_is_parkable_heavy (Folder folder) {
        return folder.is_archive_mailbox || folder.kind == FolderKind.JUNK;
    }

    /* libcamelews / camel-m365 skips post-transfer refresh_info when dest is
     * frozen — without this, Archive moves hang on a full 24k-folder sync. */
    private static void freeze_folders_for_transfer (Camel.Folder source, Camel.Folder dest) {
        source.freeze ();
        dest.freeze ();
    }

    private static void thaw_folders_for_transfer (Camel.Folder source, Camel.Folder dest) {
        dest.thaw ();
        source.thaw ();
    }

    private static bool transfer_job_is_parked (TransferFlushJob job) {
        return job.parked_until > 0 && job.parked_until > Utils.sync_tick ();
    }

    private static GenericArray<FolderNode> nodes_from_info (Camel.FolderInfo? info) {
        var nodes = new GenericArray<FolderNode> ();
        unowned Camel.FolderInfo? cursor = info;
        while (cursor != null) {
            var node = new FolderNode ();
            node.folder = new Folder () {
                name = cursor.display_name ?? cursor.full_name,
                full_name = cursor.full_name,
                unread = cursor.unread,
                total = cursor.total,
                flags = (uint) cursor.flags,
            };
            apply_folder_display_name (node.folder);
            node.children = nodes_from_info (cursor.child);
            nodes.add (node);
            cursor = cursor.next;
        }
        return nodes;
    }

    /* Map well-known folders to the UI locale. Gmail/EDS often ship display
     * names in the account language; cached trees may also freeze an older
     * locale — call this whenever a Folder is shown, not only on Camel list. */
    public static void apply_folder_display_name (Folder folder) {
        switch (folder.kind) {
            case FolderKind.INBOX: {
                var name = folder.name.down ();
                if (name == "inbox" || name == "posta in arrivo" || name == "in arrivo")
                    folder.name = C_("Mail folder", "Inbox");
                break;
            }
            case FolderKind.DRAFTS:
                folder.name = C_("Mail folder", "Drafts");
                break;
            case FolderKind.SENT:
                folder.name = C_("Mail folder", "Sent");
                break;
            case FolderKind.TRASH:
                folder.name = C_("Mail folder", "Trash");
                break;
            case FolderKind.JUNK:
                folder.name = C_("Mail folder", "Junk");
                break;
            case FolderKind.ALL:
                folder.name = C_("Mail folder", "All Mail");
                break;
            case FolderKind.STARRED:
                folder.name = C_("Mail folder", "Starred");
                break;
            case FolderKind.IMPORTANT:
                folder.name = C_("Mail folder", "Important");
                break;
            case FolderKind.ARCHIVE:
                folder.name = C_("Mail folder", "Archive");
                break;
            case FolderKind.OUTBOX:
                folder.name = C_("Mail folder", "Outbox");
                break;
            default:
                break;
        }
    }

    private static bool gmail_is_root_special (Folder folder) {
        switch (folder.kind) {
            case FolderKind.INBOX:
            case FolderKind.DRAFTS:
            case FolderKind.SENT:
            case FolderKind.TRASH:
            case FolderKind.JUNK:
            case FolderKind.ARCHIVE:
            case FolderKind.ALL:
                return true;
            default:
                return false;
        }
    }

    private static void reshape_gmail_tree (GenericArray<FolderNode> roots) {
        FolderNode? ns = null;
        for (uint i = 0; i < roots.length; i++) {
            if (roots[i].folder.is_gmail_namespace) {
                ns = roots[i];
                break;
            }
        }
        if (ns == null) {
            for (uint i = 0; i < roots.length; i++)
                reshape_gmail_tree (roots[i].children);
            return;
        }

        var kept = new GenericArray<FolderNode> ();
        for (uint i = 0; i < ns.children.length; i++) {
            var child = ns.children[i];
            if (!gmail_is_root_special (child.folder)) {
                kept.add (child);
                continue;
            }
            if (!root_has_kind (roots, child.folder.kind))
                roots.add (child);
        }
        ns.children = kept;

        var top = new GenericArray<FolderNode> ();
        for (uint i = 0; i < roots.length; i++) {
            var node = roots[i];
            if (node == ns || gmail_is_root_special (node.folder))
                top.add (node);
            else
                ns.children.add (node);
        }
        if (roots.length > 0)
            roots.remove_range (0, roots.length);
        for (uint i = 0; i < top.length; i++)
            roots.add (top[i]);
    }

    private static bool root_has_kind (GenericArray<FolderNode> roots, FolderKind kind) {
        for (uint i = 0; i < roots.length; i++) {
            if (roots[i].folder.kind == kind)
                return true;
        }
        return false;
    }

    private static void sort_folder_nodes (GenericArray<FolderNode> nodes) {
        for (uint i = 1; i < nodes.length; i++) {
            var key = nodes[i];
            uint j = i;
            while (j > 0 && folder_node_compare (nodes[j - 1], key) > 0) {
                nodes[j] = nodes[j - 1];
                j--;
            }
            nodes[j] = key;
        }

        for (uint i = 0; i < nodes.length; i++)
            sort_folder_nodes (nodes[i].children);
    }

    private static int folder_node_compare (FolderNode a, FolderNode b) {
        int rank = a.folder.sort_rank - b.folder.sort_rank;
        if (rank != 0)
            return rank;

        return a.folder.name.collate (b.folder.name);
    }

    private static bool folder_is_heavy_root (Folder folder) {
        switch (folder.kind) {
            case FolderKind.ARCHIVE:
            case FolderKind.ALL:
            case FolderKind.JUNK:
            case FolderKind.TRASH:
            case FolderKind.SENT:
            case FolderKind.DRAFTS:
            case FolderKind.OUTBOX:
                return true;
            default:
                return false;
        }
    }

    private static void flatten_folder_nodes (
        GenericArray<FolderNode> nodes,
        uint indent,
        GenericArray<Folder> folders,
        bool under_inbox,
        bool under_heavy
    ) {
        for (uint i = 0; i < nodes.length; i++) {
            var node = nodes[i];
            var in_tree = under_inbox || node.folder.kind == FolderKind.INBOX;
            var heavy_branch = under_heavy || folder_is_heavy_root (node.folder);
            if (node.folder.hidden) {
                flatten_folder_nodes (node.children, indent, folders, in_tree, heavy_branch);
                continue;
            }

            node.folder.indent = indent;
            node.folder.watch_new_mail = !heavy_branch && !node.folder.is_gmail_namespace;
            folders.add (node.folder);
            flatten_folder_nodes (node.children, indent + 1, folders, in_tree, heavy_branch);
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
        if (cancellable != null && cancellable.is_cancelled ())
            throw new IOError.CANCELLED ("Cancelled");
        if (folder.is_virtual_view)
            return new GenericArray<Message> ();

        var camel_folder = yield open_camel_folder (account, folder, null);
        if (watch)
            watch_camel_folder (account, folder, camel_folder);

        if (refresh
            && refresh_timeout_seconds != REFRESH_INFO_SKIP
            && !folder_has_pending_flags (account, folder)) {
            yield refresh_folder_info (camel_folder, high, cancellable, refresh_timeout_seconds);
        }

        if (cancellable != null && cancellable.is_cancelled ())
            throw new IOError.CANCELLED ("Cancelled");

        GenericArray<Message>? messages = null;
        var merged = false;
        uint added = 0;
        uint gone = 0;
        if (refresh && previous != null && previous.length > 0)
            messages = merge_folder_messages (account, camel_folder, folder, previous, out added, out gone);
        if (messages == null) {
            if (refresh && previous != null && previous.length > 0) {
                Utils.sync_log (
                    "headers “%s” delta too large (+%u -%u) — full collect (had %u)".printf (
                        folder.name,
                        added,
                        gone,
                        previous.length
                    )
                );
            }
            messages = yield collect_messages (account, camel_folder, folder, cancellable);
        } else {
            merged = true;
        }
        if (refresh) {
            if (merged && added == 0 && gone == 0) {
                Utils.sync_log ("headers “%s” unchanged (%u messages)".printf (
                    folder.name,
                    messages.length
                ));
            } else if (merged) {
                Utils.sync_log ("headers “%s” delta-merge +%u -%u → %u messages".printf (
                    folder.name,
                    added,
                    gone,
                    messages.length
                ));
            } else {
                Utils.sync_log ("headers “%s” full-collect (%u messages)".printf (
                    folder.name,
                    messages.length
                ));
            }
        } else if (messages.length >= 500) {
            Utils.sync_log ("headers “%s” local-summary (%u messages)".printf (
                folder.name,
                messages.length
            ));
        }

        apply_counts_from_messages (folder, messages);
        messages = retain_local_only (messages, previous);
        Conversation.prune_duplicate_sends (messages);
        apply_counts_from_messages (folder, messages);
        return messages;
    }

    public async void follow_folder (Account account, Folder folder) throws Error {
        if (folder.is_virtual_view)
            return;
        var camel_folder = yield open_camel_folder (account, folder, null);
        watch_camel_folder (account, folder, camel_folder);
    }

    public async GenericArray<Message> search_folder (
        Account account,
        Folder folder,
        SearchQuery query
    ) throws Error {
        if (query.is_empty)
            return new GenericArray<Message> ();

        var camel_folder = yield open_camel_folder (account, folder, null);
        var outgoing = folder.kind == FolderKind.SENT
            || folder.kind == FolderKind.DRAFTS
            || folder.kind == FolderKind.OUTBOX;
        var messages = new GenericArray<Message> ();
        GenericArray<string> uids;
        yield enter_camel (false);
        try {
            uids = folder_search_uids (
                camel_folder,
                header_search_expression (query, false)
            );
        } catch (Error e) {
            debug ("Indexed search %s: %s", folder.name, e.message);
            uids = new GenericArray<string> ();
        } finally {
            leave_camel (false);
        }

        if (uids.length == 0)
            return messages;

        for (uint i = 0; i < uids.length; i++) {
            var uid = uids[i];
            var info = camel_folder.get_message_info (uid);
            if (info != null) {
                var message = message_from_info (account, uid, info, folder, outgoing, camel_folder);
                if (SearchQuery.matches_message (message, query))
                    messages.add (message);
            }

            if (i % 48 == 47) {
                Idle.add (search_folder.callback);
                yield;
            }
        }

        messages.sort ((a, b) => {
            if (a.date < b.date)
                return 1;
            if (a.date > b.date)
                return -1;
            return 0;
        });
        return messages;
    }

    public static string header_search_expression (SearchQuery query, bool include_body = false) {
        if (query.is_empty)
            return "(match-all false)";

        if (query.clauses.length == 1)
            return "(match-all %s)".printf (search_clause_sexp (query.clauses[0], include_body));

        var parts = new string[query.clauses.length];
        for (uint i = 0; i < query.clauses.length; i++)
            parts[i] = search_clause_sexp (query.clauses[i], include_body);
        return "(match-all (and %s))".printf (string.joinv (" ", parts));
    }

    private static string search_clause_sexp (SearchClause clause, bool include_body) {
        var encoded = new StringBuilder ();
        Camel.SExp.encode_string (encoded, clause.folded);
        var value = encoded.str;
        switch (clause.kind) {
            case SearchFilterKind.FROM:
                return "(header-contains \"From\" %s)".printf (value);
            case SearchFilterKind.TO:
                return "(or (header-contains \"To\" %s) (header-contains \"Cc\" %s))".printf (value, value);
            default:
                return search_token_clause (clause.folded, include_body);
        }
    }

    private static string search_token_clause (string token, bool include_body = false) {
        var encoded = new StringBuilder ();
        Camel.SExp.encode_string (encoded, token);
        var value = encoded.str;
        if (include_body) {
            return "(or (header-contains \"Subject\" %s) (header-contains \"From\" %s) (header-contains \"To\" %s) (header-contains \"Cc\" %s) (body-contains %s))".printf (
                value,
                value,
                value,
                value,
                value
            );
        }

        return "(or (header-contains \"Subject\" %s) (header-contains \"From\" %s) (header-contains \"To\" %s) (header-contains \"Cc\" %s))".printf (
            value,
            value,
            value,
            value
        );
    }

    /* Camel 3.58+: dup_uids / search_sync / weak transferred UIDs.
     * Camel ≤3.56: get_uids+free_uids / search_by_expression+search_free / owned UIDs. */
    private static GenericArray<string> folder_list_uids (Camel.Folder camel_folder) {
        var uids = new GenericArray<string> ();
#if HAVE_CAMEL_3_58
        var raw = camel_folder.dup_uids ();
        for (uint i = 0; i < raw.length; i++)
            uids.add (raw[i]);
#else
        unowned GenericArray<string> raw = camel_folder.get_uids ();
        for (uint i = 0; i < raw.length; i++)
            uids.add (raw[i]);
        camel_folder.free_uids (raw);
#endif
        return uids;
    }

    private static GenericArray<string> folder_search_uids (
        Camel.Folder camel_folder,
        string expression
    ) throws Error {
#if HAVE_CAMEL_3_58
        GenericArray<weak string>? found = null;
        camel_folder.search_sync (expression, out found, null);
        var uids = new GenericArray<string> ();
        if (found == null)
            return uids;
        for (uint i = 0; i < found.length; i++)
            uids.add (found[i]);
        return uids;
#else
        var found = camel_folder.search_by_expression (expression, null);
        var uids = new GenericArray<string> ();
        for (uint i = 0; i < found.length; i++)
            uids.add (found[i]);
        camel_folder.search_free (found);
        return uids;
#endif
    }

    /* Matches camel_search_util_hash_message_id / FolderSearch.util_hash_message_id
     * (first 8 bytes of MD5), so conversation threading stays compatible. */
    private static uint64 hash_message_id (string message_id, bool needs_decode) {
        string text = message_id;
        if (needs_decode) {
            var decoded = Camel.header_msgid_decode (message_id);
            if (decoded != null && decoded.length > 0)
                text = decoded;
        }
        if (text.length == 0)
            return 0;

        var checksum = new Checksum (ChecksumType.MD5);
        checksum.update (text.data, text.length);
        uint8[] digest = new uint8[16];
        size_t digest_len = digest.length;
        checksum.get_digest (digest, ref digest_len);
        uint64 hash = 0;
        Memory.copy (&hash, digest, sizeof (uint64));
        return hash;
    }

    public static bool folder_is_heavy (Folder folder) {
        return folder.is_archive_mailbox
            || folder.kind == FolderKind.JUNK
            || folder.kind == FolderKind.TRASH;
    }

    /* Camel folder summary size (local SQLite / on-disk UIDs). Does not hit the
     * network — used to detect Letter header-list caches that lag behind Camel. */
    public async int local_uid_count (
        Account account,
        Folder folder,
        Cancellable? cancellable = null
    ) throws Error {
        if (folder.is_virtual_view)
            return 0;
        var camel_folder = yield open_camel_folder (account, folder, cancellable);
        yield enter_camel (false);
        try {
            return (int) folder_list_uids (camel_folder).length;
        } finally {
            leave_camel (false);
        }
    }

    public async bool remote_counts_differ (
        Account account,
        Folder folder,
        int local_total,
        int local_unread,
        Cancellable? cancellable = null
    ) throws Error {
        int remote_total = -1;
        int remote_unread = -1;
        if (!yield query_remote_counts (account, folder.full_name, cancellable, out remote_total, out remote_unread))
            return false;

        if (remote_total >= 0)
            folder.total = int.max (folder.total, remote_total);
        if (remote_unread >= 0)
            folder.unread = remote_unread;

        if (remote_total >= 0 && remote_total != local_total)
            return true;
        if (remote_unread >= 0 && remote_unread != local_unread)
            return true;
        return false;
    }

    private async void enter_camel (bool high) {
        if (high)
            this.high_refresh_waiters++;

        var spins = 0;
        while (this.camel_busy || (!high && this.high_refresh_waiters > 0)) {
            /* Do not steal from flush for open-body (can leave Graph mid-move
             * and resurrect mail). Send may preempt after a short wait so
             * outbound mail is not blocked behind a slow transfer flush. */
            if (high && spins >= 100) {
                var flush_holds = this.transfer_flush_running || this.flag_flush_running;
                if (flush_holds && this.send_waiters > 0) {
                    /* Ask in-flight move/flag Graph work to abort; flushes pause
                     * on send_waiters between chunks. Steal only if cancel is ignored. */
                    if (this.transfer_op_cancellable != null
                        && !this.transfer_op_cancellable.is_cancelled ()) {
                        Utils.sync_log ("Camel lock: cancelling move so send can proceed");
                        this.transfer_op_cancellable.cancel ();
                    }
                    if (this.flag_op_cancellable != null
                        && !this.flag_op_cancellable.is_cancelled ()) {
                        Utils.sync_log ("Camel lock: cancelling flag sync so send can proceed");
                        this.flag_op_cancellable.cancel ();
                    }
                    if (spins >= 500) {
                        Utils.sync_log ("Camel lock: send preempting local flush");
                        this.camel_epoch++;
                        this.camel_busy = false;
                        break;
                    }
                    if (spins == 100 || spins % 100 == 0) {
                        Utils.sync_log ("Camel lock: waiting for flush to yield to send");
                    }
                } else if (flush_holds
                    && this.flag_op_cancellable != null
                    && !this.flag_op_cancellable.is_cancelled ()) {
                    /* Draft / open-body: abort bulk SEEN synchronize so high work
                     * can take Camel. Do not cancel in-flight moves (open-body
                     * must not interrupt Graph transfers). */
                    Utils.sync_log ("Camel lock: cancelling flag sync for priority work");
                    this.flag_op_cancellable.cancel ();
                } else if (spins >= 1000) {
                    if (flush_holds) {
                        if (spins == 1000 || spins % 500 == 0) {
                            Utils.sync_log ("Camel lock held by local flush — priority still waiting");
                        }
                    } else {
                        Utils.sync_log ("Camel lock stuck — stealing for priority work (send/open)");
                        this.camel_epoch++;
                        this.camel_busy = false;
                        break;
                    }
                }
            }
            Timeout.add (high ? 20 : 80, enter_camel.callback);
            yield;
            spins++;
        }

        this.camel_busy = true;
        this.camel_owner_epoch = this.camel_epoch;
    }

    private void leave_camel (bool high) {
        if (this.camel_owner_epoch == this.camel_epoch)
            this.camel_busy = false;
        else
            Utils.sync_log ("stale Camel leave ignored (lock was stolen)");
        if (high)
            this.high_refresh_waiters--;
    }

    /* Link parent cancel + a wall-clock timeout so Graph calls cannot hold Camel forever. */
    private static Cancellable bound_cancellable (Cancellable? parent, uint seconds, out ulong parent_id, out uint timeout_id) {
        var timed = new Cancellable ();
        parent_id = 0;
        if (parent != null) {
            if (parent.is_cancelled ())
                timed.cancel ();
            else {
                parent_id = parent.connect (() => {
                    timed.cancel ();
                });
            }
        }
        timeout_id = Timeout.add_seconds (seconds, () => {
            if (!timed.is_cancelled ()) {
                Utils.sync_log ("Camel op timeout (%us) — cancelling".printf (seconds));
                timed.cancel ();
            }
            return Source.REMOVE;
        });
        return timed;
    }

    private static void unbind_cancellable (Cancellable? parent, ulong parent_id, uint timeout_id) {
        if (timeout_id != 0)
            Source.remove (timeout_id);
        if (parent != null && parent_id != 0)
            parent.disconnect (parent_id);
    }

    /* 0 → default (HIGH 45s / LOW 90s). REFRESH_INFO_SKIP → merge Camel only. */
    public const uint REFRESH_INFO_SKIP = uint.MAX;
    public const uint REFRESH_INFO_BRIEF = 15;
    public const uint REFRESH_INFO_NORMAL = 45;
    public const uint REFRESH_INFO_FULL = 90;
    /* Explicit Update Folder — only wall-clock ends it (matches sync interval). */
    public const uint REFRESH_INFO_FORCE = 300;

    private async void refresh_folder_info (
        Camel.Folder camel_folder,
        bool high,
        Cancellable? cancellable = null,
        uint timeout_seconds = 0
    ) {
        yield enter_camel (high);
        var timed = new Cancellable ();
        ulong cancel_id = 0;
        if (cancellable != null) {
            if (cancellable.is_cancelled ()) {
                timed.cancel ();
            } else {
                cancel_id = cancellable.connect (() => {
                    timed.cancel ();
                });
            }
        }
        /* Graph refresh_info can hang indefinitely on some folders; bound it so
         * send / open-body / Inbox checks can recover via preempt. Scout uses a
         * shorter budget on warm bulk folders and widens only if drift remains. */
        var seconds = timeout_seconds;
        if (seconds == 0)
            seconds = high ? REFRESH_INFO_NORMAL : REFRESH_INFO_FULL;
        var timeout_id = Timeout.add_seconds (seconds, () => {
            if (!timed.is_cancelled ()) {
                Utils.sync_log ("Camel refresh_info timeout (%us) — cancelling".printf (seconds));
                timed.cancel ();
            }
            return Source.REMOVE;
        });
        try {
            var name = camel_folder.get_full_display_name () ?? camel_folder.get_full_name ();
            var t0 = Utils.sync_tick ();
            /* Graph: skip prepare_content_refresh — it resets the delta cursor. */
            yield camel_folder.refresh_info (high ? Priority.DEFAULT : Priority.LOW, timed);
            Utils.sync_log ("Camel refresh_info “%s” %s %s".printf (
                name,
                high ? "HIGH" : "LOW",
                Utils.sync_ms (t0)
            ));
        } catch (Error e) {
            if (e is IOError.CANCELLED)
                Utils.sync_log ("Camel refresh_info CANCELLED");
            else {
                Utils.sync_log ("Camel refresh_info FAILED: %s".printf (e.message));
                warning ("Could not refresh folder: %s", e.message);
            }
        } finally {
            if (timeout_id != 0)
                Source.remove (timeout_id);
            if (cancel_id != 0 && cancellable != null)
                cancellable.disconnect (cancel_id);
            leave_camel (high);
        }
    }

    private async Camel.MimeMessage? fetch_camel_message (
        Camel.Folder camel_folder,
        string uid,
        int io_priority,
        Cancellable? cancellable = null
    ) throws Error {
        var high = io_priority < Priority.LOW;
        yield enter_camel (high);
        try {
            return yield camel_folder.get_message (uid, io_priority, cancellable);
        } finally {
            leave_camel (high);
        }
    }

    private async bool query_remote_counts (
        Account account,
        string full_name,
        Cancellable? cancellable,
        out int total,
        out int unread
    ) throws Error {
        total = -1;
        unread = -1;
        var store = yield open_store (account, cancellable);
        var flags = Camel.StoreGetFolderInfoFlags.SUBSCRIBED
            | Camel.StoreGetFolderInfoFlags.NO_VIRTUAL
            | Camel.StoreGetFolderInfoFlags.REFRESH;
        yield enter_camel (false);
        Camel.FolderInfo? info = null;
        try {
            info = yield store.get_folder_info (full_name, flags, Priority.DEFAULT, cancellable);
        } finally {
            leave_camel (false);
        }
        var match = find_folder_info (info, full_name) ?? info;
        if (match == null)
            return false;

        total = match.total;
        unread = match.unread;
        return total >= 0 || unread >= 0;
    }

    private static unowned Camel.FolderInfo? find_folder_info (Camel.FolderInfo? info, string full_name) {
        unowned Camel.FolderInfo? cursor = info;
        while (cursor != null) {
            if (cursor.full_name == full_name)
                return cursor;

            unowned var child = find_folder_info (cursor.child, full_name);
            if (child != null)
                return child;

            cursor = cursor.next;
        }

        return null;
    }

    private static void apply_counts_from_messages (Folder folder, GenericArray<Message> messages) {
        int unread = 0;
        for (uint i = 0; i < messages.length; i++) {
            if (!messages[i].seen)
                unread++;
        }

        folder.unread = unread;
        folder.total = (int) messages.length;
    }

    private static void apply_camel_counts (Folder folder, Camel.Folder camel_folder) {
        var uids = folder_list_uids (camel_folder);
        int total = (int) uids.length;
        int unread = 0;
        for (uint i = 0; i < uids.length; i++) {
            var info = camel_folder.get_message_info (uids[i]);
            if (info != null && (info.get_flags () & Camel.MessageFlags.SEEN) == 0)
                unread++;
        }

        folder.unread = unread;
        folder.total = total < 0 ? 0 : total;
    }

    private async GenericArray<Message> collect_messages (
        Account account,
        Camel.Folder camel_folder,
        Folder folder,
        Cancellable? cancellable
    ) throws Error {
        var outgoing = folder.kind == FolderKind.SENT
            || folder.kind == FolderKind.DRAFTS
            || folder.kind == FolderKind.OUTBOX;
        var t0 = Utils.sync_tick ();
        var uids = folder_list_uids (camel_folder);
        var total = uids.length;
        if (total >= 500) {
            Utils.sync_log ("collect_messages “%s” begin %u uids".printf (folder.name, total));
        }
        var messages = new GenericArray<Message> ();
        for (uint i = 0; i < total; i++) {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Cancelled");

            var info = camel_folder.get_message_info (uids[i]);
            if (info != null)
                messages.add (message_from_info (account, uids[i], info, folder, outgoing, camel_folder));

            if (i % 48 == 47) {
                if (total >= 2000 && (i + 1) % 2000 == 0) {
                    Utils.sync_log ("collect_messages “%s” %u/%u %s".printf (
                        folder.name,
                        i + 1,
                        total,
                        Utils.sync_ms (t0)
                    ));
                }
                Idle.add (collect_messages.callback);
                yield;
            }
        }

        if (total >= 500) {
            Utils.sync_log ("collect_messages “%s” done %u msgs %s".printf (
                folder.name,
                messages.length,
                Utils.sync_ms (t0)
            ));
        }

        messages.sort ((a, b) => {
            if (a.date < b.date)
                return 1;
            if (a.date > b.date)
                return -1;
            return 0;
        });
        return messages;
    }

    private GenericArray<Message>? merge_folder_messages (
        Account account,
        Camel.Folder camel_folder,
        Folder folder,
        GenericArray<Message> previous,
        out uint added,
        out uint gone
    ) {
        added = 0;
        gone = 0;
        var uids = folder_list_uids (camel_folder);
        var have = new HashTable<string, Message> (str_hash, str_equal);
        for (uint i = 0; i < previous.length; i++)
            have.set (previous[i].uid, previous[i]);

        var live = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < uids.length; i++) {
            live.set (uids[i], 1);
            if (!have.contains (uids[i]))
                added++;
        }

        for (uint i = 0; i < previous.length; i++) {
            if (!live.contains (previous[i].uid))
                gone++;
        }

        if (added == 0 && gone == 0) {
            if (previous.length != uids.length)
                return null;
            /* UID set unchanged — still refresh seen/flagged from Camel so
             * badges and bookmarks stay cache-correct without a full collect. */
            for (uint i = 0; i < previous.length; i++) {
                var info = camel_folder.get_message_info (previous[i].uid);
                if (info == null)
                    continue;
                apply_info_flags (account, folder, previous[i], info);
            }
            return previous;
        }
        /* Allow larger deltas on bulk folders (phone moved many mails) before
         * giving up and rebuilding tens of thousands of headers. */
        var max_delta = folder_is_heavy (folder) || folder.kind == FolderKind.SENT
            ? 2000
            : 500;
        if (added + gone > max_delta)
            return null;

        var outgoing = folder.kind == FolderKind.SENT
            || folder.kind == FolderKind.DRAFTS
            || folder.kind == FolderKind.OUTBOX;
        var result = new GenericArray<Message> ();
        for (uint i = 0; i < uids.length; i++) {
            var uid = uids[i];
            var old = have.get (uid);
            if (old != null) {
                var info = camel_folder.get_message_info (uid);
                if (info != null)
                    apply_info_flags (account, folder, old, info);
                result.add (old);
            } else {
                var info = camel_folder.get_message_info (uid);
                if (info == null)
                    continue;
                result.add (message_from_info (account, uid, info, folder, outgoing, camel_folder));
            }
        }

        if (result.length != uids.length)
            return null;

        result.sort ((a, b) => {
            if (a.date < b.date)
                return 1;
            if (a.date > b.date)
                return -1;
            return 0;
        });
        return result;
    }

    private static GenericArray<Message> retain_local_only (
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

        live.sort ((a, b) => {
            if (a.date < b.date)
                return 1;
            if (a.date > b.date)
                return -1;
            return 0;
        });
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

    private static bool uses_outlook_flag_semantics (Account account) {
        return account.kind == AccountKind.MICROSOFT || account.kind == AccountKind.EXCHANGE;
    }

    /* evolution-ews maps Graph/EWS High Importance → CAMEL_MESSAGE_FLAGGED, and
     * Outlook "Flag" (follow-up) → the follow-up user tag. Letter bookmarks must
     * follow the latter on Microsoft accounts, or Importance shows as a phantom bookmark. */
    private static bool info_has_active_followup (Camel.MessageInfo info) {
        var follow = info.dup_user_tag ("follow-up");
        if (follow == null || follow.length == 0)
            return false;
        var completed = info.dup_user_tag ("completed-on");
        return completed == null || completed.length == 0;
    }

    private static void apply_info_flags (
        Account account,
        Folder folder,
        Message message,
        Camel.MessageInfo info
    ) {
        var flags = info.get_flags ();
        message.seen = (flags & Camel.MessageFlags.SEEN) != 0;
        if (uses_outlook_flag_semantics (account)) {
            message.flagged = info_has_active_followup (info);
            message.important = (flags & Camel.MessageFlags.FLAGGED) != 0
                || folder.kind == FolderKind.IMPORTANT;
        } else {
            message.flagged = (flags & Camel.MessageFlags.FLAGGED) != 0;
            if (folder.kind == FolderKind.IMPORTANT)
                message.important = true;
        }
    }

    private static Message message_from_info (
        Account account,
        string uid,
        Camel.MessageInfo info,
        Folder folder,
        bool outgoing,
        Camel.Folder? camel_folder = null
    ) {
        int64 date = info.get_date_received ();
        if (date <= 0)
            date = info.get_date_sent ();

        var subject = info.get_subject ();
        if (subject == null || subject.length == 0)
            subject = _("(No subject)");

        var preview = info.get_preview ();
        if (preview != null && preview.length == 0)
            preview = null;

        var from_raw = info.get_from ();
        var to_raw = info.get_to ();
        var cc_raw = info.get_cc ();
        var from = Utils.display_address (from_raw);
        var to = Utils.display_address_list (to_raw);
        var cc = Utils.display_address_list (cc_raw);
        var list_address = outgoing && to.length > 0 ? to : from;
        var blob = new StringBuilder ();
        Utils.append_search_part (blob, subject);
        Utils.append_search_part (blob, from_raw);
        Utils.append_search_part (blob, to_raw);
        Utils.append_search_part (blob, cc_raw);
        Utils.append_search_part (blob, info.get_mlist ());
        Utils.append_search_part (blob, preview);
        var from_blob = new StringBuilder ();
        Utils.append_search_part (from_blob, from);
        Utils.append_search_part (from_blob, from_raw);
        var to_blob = new StringBuilder ();
        Utils.append_search_part (to_blob, to);
        Utils.append_search_part (to_blob, to_raw);
        Utils.append_search_part (to_blob, cc);
        Utils.append_search_part (to_blob, cc_raw);
        Utils.append_search_part (to_blob, list_address);

        var flags = info.get_flags ();
        var flagged = uses_outlook_flag_semantics (account)
            ? info_has_active_followup (info)
            : (flags & Camel.MessageFlags.FLAGGED) != 0;
        var important = folder.kind == FolderKind.IMPORTANT
            || (uses_outlook_flag_semantics (account) && (flags & Camel.MessageFlags.FLAGGED) != 0);

        return new Message () {
            uid = uid,
            subject = subject,
            from = from,
            to = to,
            cc = cc,
            from_blob = from_blob.str,
            to_blob = to_blob.str,
            list_address = list_address,
            date = date,
            seen = (flags & Camel.MessageFlags.SEEN) != 0,
            flagged = flagged,
            important = important,
            has_attachment = (flags & Camel.MessageFlags.ATTACHMENTS) != 0,
            preview = preview,
            folder_name = folder.name,
            folder_full_name = folder.full_name,
            outgoing = outgoing,
            msgid_hash = info.get_message_id (),
            msgid_refs = msgid_refs_from_info (info, camel_folder, uid),
            conversation_key = conversation_key_from_info (info),
            search_blob = blob.str,
        };
    }

    private static Message message_from_mime (
        string uid,
        Camel.MimeMessage mime,
        Folder folder,
        string body
    ) {
        var subject = mime.get_subject ();
        if (subject == null || subject.length == 0)
            subject = _("(No subject)");

        int offset = 0;
        int64 date = (int64) mime.get_date (out offset);
        if (date <= 0)
            date = new DateTime.now_local ().to_unix ();

        var from = Utils.format_internet_address (mime.get_from ());
        var to = Utils.format_internet_address (mime.get_recipients (Camel.RECIPIENT_TYPE_TO));
        var cc = Utils.format_internet_address (mime.get_recipients (Camel.RECIPIENT_TYPE_CC));
        var preview = body.strip ().replace ("\n", " ");
        if (preview.length > 140)
            preview = preview.substring (0, 140);

        var msgid = mime.get_message_id ();
        var medium = (Camel.Medium) mime;
        var from_display = from.length > 0 ? Utils.display_address (from) : from;
        var to_display = Utils.display_address_list (to);
        var cc_display = Utils.display_address_list (cc);
        var blob = new StringBuilder ();
        Utils.append_search_part (blob, subject);
        Utils.append_search_part (blob, from);
        Utils.append_search_part (blob, to);
        Utils.append_search_part (blob, cc);
        Utils.append_search_part (blob, body);
        var from_blob = new StringBuilder ();
        Utils.append_search_part (from_blob, from_display);
        Utils.append_search_part (from_blob, from);
        var to_blob = new StringBuilder ();
        Utils.append_search_part (to_blob, to_display);
        Utils.append_search_part (to_blob, to);
        Utils.append_search_part (to_blob, cc_display);
        Utils.append_search_part (to_blob, cc);
        return new Message () {
            uid = uid,
            subject = subject,
            from = from_display,
            to = to_display,
            cc = cc_display,
            from_blob = from_blob.str,
            to_blob = to_blob.str,
            list_address = to_display,
            date = date,
            seen = true,
            has_attachment = mime.has_attachment (),
            preview = preview.length > 0 ? preview : null,
            folder_name = folder.name,
            folder_full_name = folder.full_name,
            outgoing = true,
            msgid_hash = msgid != null && msgid.length > 0
                ? hash_message_id (msgid, true)
                : 0,
            msgid_refs = hashes_from_id_headers (
                medium.get_header ("In-Reply-To"),
                medium.get_header ("References")
            ),
            conversation_key = conversation_key_from_headers (
                medium.get_header ("Conversation-ID") ?? medium.get_header ("X-Conversation-ID"),
                medium.get_header ("X-GM-THRID"),
                medium.get_header ("Thread-Index")
            ),
            local_only = uid.has_prefix ("local-sent-") || uid.has_prefix ("local-draft-"),
            search_blob = blob.str,
            important = MessageContent.mime_has_high_priority (mime),
        };
    }

    private static uint64[] msgid_refs_from_info (
        Camel.MessageInfo info,
        Camel.Folder? camel_folder,
        string uid
    ) {
        var seen = new HashTable<string, uint8> (str_hash, str_equal);
        var list = new Array<uint64> ();

        unowned GLib.Array<uint64>? refs = info.get_references ();
        if (refs != null) {
            for (uint i = 0; i < refs.length; i++)
                append_msgid_hash (list, seen, refs.index (i));
        }

        // Some clients (old Outlook / third-party gateways) store In-Reply-To
        // and References as RFC 2047 encoded-words. Camel's summary may miss
        // those links; decode and re-parse from headers and the local MIME.
        collect_msgid_hashes (list, seen, info_header (info, "In-Reply-To"));
        collect_msgid_hashes (list, seen, info_header (info, "References"));

        if (camel_folder != null) {
            var mime = message_from_local_cache (camel_folder, uid);
            if (mime != null) {
                var medium = (Camel.Medium) mime;
                collect_msgid_hashes (list, seen, medium.get_header ("In-Reply-To"));
                collect_msgid_hashes (list, seen, medium.get_header ("References"));
            }
        }

        if (list.length == 0)
            return {};

        var copy = new uint64[list.length];
        for (uint i = 0; i < list.length; i++)
            copy[i] = list.index (i);
        return copy;
    }

    private static void append_msgid_hash (
        Array<uint64> list,
        HashTable<string, uint8> seen,
        uint64 hash
    ) {
        if (hash == 0)
            return;
        var key = hash.to_string ();
        if (seen.contains (key))
            return;
        seen.set (key, 1);
        list.append_val (hash);
    }

    private static string? conversation_key_from_info (Camel.MessageInfo info) {
        var conversation_id = info_header (info, "Conversation-ID");
        if (conversation_id == null || conversation_id.strip ().length == 0)
            conversation_id = info_header (info, "X-Conversation-ID");
        return conversation_key_from_headers (
            conversation_id,
            info_header (info, "X-GM-THRID"),
            info_header (info, "Thread-Index")
        );
    }

    private static string? info_header (Camel.MessageInfo info, string name) {
        var value = info.get_user_header (name);
        if (value != null && value.strip ().length > 0)
            return value;
        var headers = info.get_headers ();
        if (headers == null)
            return null;
        return headers.get_named (Camel.CompareType.INSENSITIVE, name);
    }

    private static string? conversation_key_from_headers (
        string? conversation_id,
        string? gm_thrid,
        string? thread_index
    ) {
        var cid = unfold_header (conversation_id);
        if (cid.length > 0)
            return "cid:%s".printf (cid.casefold ());

        var gm = unfold_header (gm_thrid);
        if (gm.length > 0)
            return "gm:%s".printf (gm);

        var root = thread_index_root (thread_index);
        if (root != null)
            return "ti:%s".printf (root);
        return null;
    }

    private static string? thread_index_root (string? raw) {
        var compact = compact_header (raw);
        if (compact.length == 0)
            return null;

        uint8[] decoded = Base64.decode (compact);
        if (decoded.length < 22)
            return null;

        var root = new uint8[22];
        for (int i = 0; i < 22; i++)
            root[i] = decoded[i];
        return Base64.encode (root);
    }

    private static uint64[] hashes_from_id_headers (string? in_reply_to, string? references) {
        var seen = new HashTable<string, uint8> (str_hash, str_equal);
        var list = new Array<uint64> ();
        collect_msgid_hashes (list, seen, in_reply_to);
        collect_msgid_hashes (list, seen, references);
        if (list.length == 0)
            return {};

        var copy = new uint64[list.length];
        for (uint i = 0; i < list.length; i++)
            copy[i] = list.index (i);
        return copy;
    }

    private static void collect_msgid_hashes (
        Array<uint64> list,
        HashTable<string, uint8> seen,
        string? raw
    ) {
        if (raw == null || raw.length == 0)
            return;

        var text = decode_identity_header (raw);
        if (text.length == 0)
            return;

        int i = 0;
        bool found = false;
        while (i < text.length) {
            var start = text.index_of_char ('<', i);
            if (start < 0)
                break;
            var end = text.index_of_char ('>', start + 1);
            if (end < 0)
                break;
            found = true;
            add_msgid_hash (list, seen, text.substring (start, end - start + 1));
            i = end + 1;
        }
        if (!found)
            add_msgid_hash (list, seen, text);
    }

    private static string decode_identity_header (string raw) {
        // Decode RFC 2047 encoded-words first so =3C...=3E become <...>.
        var decoded = Camel.header_decode_string (raw, "UTF-8");
        if (decoded != null && decoded.length > 0)
            return unfold_header (decoded);
        return unfold_header (raw);
    }

    private static void add_msgid_hash (
        Array<uint64> list,
        HashTable<string, uint8> seen,
        string raw
    ) {
        var id = unfold_header (raw);
        if (id.length == 0)
            return;
        var hash = hash_message_id (id, true);
        append_msgid_hash (list, seen, hash);
    }

    private static string folder_watch_key (Account account, Folder folder) {
        return "%s\n%s".printf (account.source_uid ?? account.uid, folder.full_name);
    }

    private void watch_camel_folder (Account account, Folder folder, Camel.Folder camel_folder) {
        var key = folder_watch_key (account, folder);
        var existing = this.folder_watches.get (key);
        if (existing != null && existing.camel_folder == camel_folder)
            return;
        if (existing != null)
            drop_watch (key);

        var watch = new FolderWatch ();
        watch.camel_folder = camel_folder;
        watch.account_key = account.source_uid ?? account.uid;
        watch.folder_name = folder.full_name;
        watch.changed_id = camel_folder.changed.connect ((changes) => {
            schedule_folder_changed (watch);
        });
        this.folder_watches.set (key, watch);
    }

    public void unwatch_all_folders () {
        var keys = new GenericArray<string> ();
        this.folder_watches.foreach ((key, watch) => {
            keys.add (key);
        });
        for (uint i = 0; i < keys.length; i++)
            drop_watch (keys[i]);
    }

    public void unwatch_account_folders (string account_key) {
        var keys = new GenericArray<string> ();
        this.folder_watches.foreach ((key, watch) => {
            if (watch.account_key == account_key)
                keys.add (key);
        });
        for (uint i = 0; i < keys.length; i++)
            drop_watch (keys[i]);
    }

    private void drop_watch (string key) {
        var watch = this.folder_watches.get (key);
        if (watch == null)
            return;
        this.folder_watches.remove (key);
        if (watch.idle != 0) {
            Source.remove (watch.idle);
            watch.idle = 0;
        }
        var folder = watch.camel_folder;
        var id = watch.changed_id;
        watch.changed_id = 0;
        watch.camel_folder = null;
        if (folder == null || id == 0)
            return;
        if (SignalHandler.is_connected (folder, id))
            folder.disconnect (id);
    }

    private void schedule_folder_changed (FolderWatch watch) {
        if (watch.idle != 0)
            return;

        watch.idle = Timeout.add (200, () => {
            watch.idle = 0;
            folder_changed (watch.account_key, watch.folder_name);
            return Source.REMOVE;
        });
    }

    public GenericArray<string> apply_live_flags (Account account, Folder folder, GenericArray<Message> messages) {
        var removed = new GenericArray<string> ();
        var watch = this.folder_watches.get (folder_watch_key (account, folder));
        if (watch == null || watch.camel_folder == null)
            return removed;

        for (uint i = 0; i < messages.length; i++) {
            if (messages[i].is_placeholder)
                continue;
            var info = watch.camel_folder.get_message_info (messages[i].uid);
            if (info == null) {
                removed.add (messages[i].uid);
                continue;
            }

            apply_info_flags (account, folder, messages[i], info);
        }

        apply_counts_from_messages (folder, messages);
        return removed;
    }

    public uint append_live_headers (Account account, Folder folder, GenericArray<Message> messages) {
        var watch = this.folder_watches.get (folder_watch_key (account, folder));
        if (watch == null || watch.camel_folder == null)
            return 0;

        var have = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < messages.length; i++)
            have.set (messages[i].uid, 1);

        var outgoing = folder.kind == FolderKind.SENT
            || folder.kind == FolderKind.DRAFTS
            || folder.kind == FolderKind.OUTBOX;
        var uids = folder_list_uids (watch.camel_folder);
        uint added = 0;
        for (uint i = 0; i < uids.length; i++) {
            if (have.contains (uids[i]))
                continue;
            var info = watch.camel_folder.get_message_info (uids[i]);
            if (info == null)
                continue;
            messages.add (message_from_info (account, uids[i], info, folder, outgoing, watch.camel_folder));
            added++;
        }

        var before_prune = messages.length;
        Conversation.prune_duplicate_sends (messages);
        if (added == 0 && messages.length == before_prune)
            return 0;
        if (added == 0)
            added = before_prune - messages.length;

        messages.sort ((a, b) => {
            if (a.date < b.date)
                return 1;
            if (a.date > b.date)
                return -1;
            return 0;
        });
        apply_counts_from_messages (folder, messages);
        return added;
    }

    public MessageContent? peek_body (Account account, Folder folder, string uid) {
        return this.body_cache.get (body_key (account, folder, uid));
    }

    public void rekey_body (Account account, Folder from, string old_uid, Folder dest, string new_uid) {
        var dest_key = body_key (account, dest, new_uid);
        var from_key = body_key (account, from, old_uid);
        var dest_old_key = body_key (account, dest, old_uid);
        var content = this.body_cache.get (from_key)
            ?? this.body_cache.get (dest_old_key)
            ?? this.body_cache.get (dest_key);
        if (content == null)
            return;

        if (from_key != dest_key)
            this.body_cache.remove (from_key);
        if (old_uid != new_uid)
            this.body_cache.remove (dest_old_key);

        content.uid = new_uid;
        this.body_cache.set (dest_key, content);
    }

    public async MessageContent load_message (Account account, Folder folder, string uid, Cancellable? cancellable = null) throws Error {
        var key = body_key (account, folder, uid);
        var cached = this.body_cache.get (key);
        if (cached != null)
            return cached;

        var camel_folder = yield open_camel_folder (account, folder, null);
        var mime = message_from_local_cache (camel_folder, uid);
        if (mime != null)
            Utils.sync_log ("open body “%s” uid=%s from disk".printf (folder.name, uid));
        if (mime == null) {
            Utils.sync_log ("open body “%s” uid=%s from server".printf (folder.name, uid));
            try {
                mime = yield fetch_camel_message (camel_folder, uid, Priority.DEFAULT, cancellable);
            } catch (Error e) {
                mime = message_from_local_cache (camel_folder, uid);
                if (mime == null) {
                    if (is_missing_on_server (e)) {
                        throw new IOError.NOT_FOUND (
                            _("This message is still syncing with the server. Try again in a moment.")
                        );
                    }
                    throw e;
                }
            }
        }
        if (mime == null) {
            throw new IOError.NOT_FOUND (
                _("Message could not be opened.")
            );
        }

        var fetched = MessageContent.from_mime (uid, mime);
        this.body_cache.set (key, fetched);
        return fetched;
    }

    public async void export_message_eml (
        Account account,
        Folder folder,
        string uid,
        File dest,
        Cancellable? cancellable = null
    ) throws Error {
        var camel_folder = yield open_camel_folder (account, folder, cancellable);
        var mime = message_from_local_cache (camel_folder, uid);
        if (mime == null) {
            try {
                mime = yield fetch_camel_message (camel_folder, uid, Priority.DEFAULT, cancellable);
            } catch (Error e) {
                mime = message_from_local_cache (camel_folder, uid);
                if (mime == null) {
                    if (is_missing_on_server (e)) {
                        throw new IOError.NOT_FOUND (
                            _("This message is still syncing with the server. Try again in a moment.")
                        );
                    }
                    throw e;
                }
            }
        }
        if (mime == null) {
            throw new IOError.NOT_FOUND (
                _("Message could not be opened.")
            );
        }

        var stream = yield dest.replace_async (
            null,
            false,
            FileCreateFlags.REPLACE_DESTINATION,
            Priority.DEFAULT,
            cancellable
        );
        try {
            yield mime.write_to_output_stream (stream, Priority.DEFAULT, cancellable);
            yield stream.close_async (Priority.DEFAULT, cancellable);
        } catch (Error e) {
            try {
                yield stream.close_async (Priority.DEFAULT, null);
            } catch (Error ignore) {
            }
            throw e;
        }
    }

    public void queue_mark_seen (Account account, Folder folder, string uid) {
        set_message_seen.begin (account, folder, uid, true, null, (obj, res) => {
            try {
                set_message_seen.end (res);
            } catch (Error e) {
                debug ("Could not mark message as read: %s", e.message);
            }
        });
    }

    public async void set_message_seen (
        Account account,
        Folder folder,
        string uid,
        bool seen,
        Cancellable? cancellable = null
    ) throws Error {
        var camel_folder = yield open_camel_folder (account, folder, cancellable);
        /* evolution-ews always uploads the full Graph `flag` object with isRead.
         * If we have no local Flag yet and the summary isn't dirty, refresh so a
         * remote Outlook Contrassegno is present and not wiped on push. Skip when
         * local tags are already set/cleared (pending bookmark write). */
        if (uses_outlook_flag_semantics (account)) {
            var info = camel_folder.get_message_info (uid);
            if (info != null && !info_has_active_followup (info) && !info.get_folder_flagged ())
                yield refresh_folder_info (camel_folder, true);
        }

        var flags = camel_folder.get_message_flags (uid);
        var currently_seen = (flags & Camel.MessageFlags.SEEN) != 0;
        if (currently_seen == seen)
            return;

        camel_folder.set_message_flags (
            uid,
            Camel.MessageFlags.SEEN,
            seen ? Camel.MessageFlags.SEEN : 0
        );
        apply_camel_counts (folder, camel_folder);
        var uids = new GenericArray<string> ();
        uids.add (uid);
        enqueue_flag_flush (account, folder, uids);
    }

    public async uint prefetch_recent (
        Account account,
        Folder folder,
        GenericArray<Message> listed,
        int days,
        Cancellable? cancellable = null
    ) throws Error {
        int64 cutoff = body_cache_cutoff (days);
        var camel_folder = yield open_camel_folder (account, folder, null);
        var cursor_key = prefetch_cursor_key (account, folder);
        ensure_prefetch_cursors_loaded ();
        int start = 0;
        if (this.prefetch_cursor.contains (cursor_key))
            start = this.prefetch_cursor.get (cursor_key);
        if (start < 0 || start > (int) listed.length)
            start = 0;

        uint stored = 0;
        uint skipped_disk = 0;
        int i = start;
        var t0 = Utils.sync_tick ();

        for (; i < (int) listed.length && stored < PREFETCH_NETWORK_CHUNK; i++) {
            if (cancellable != null && cancellable.is_cancelled ())
                break;

            var message = listed[i];
            if (cutoff > 0 && message.date > 0 && message.date < cutoff)
                break;
            if (this.body_cache.contains (body_key (account, folder, message.uid)))
                continue;
            /* Filename check only — never get_message_cached() here (that loads
             * the full MIME into RAM just to probe). */
            if (message_body_file_exists (camel_folder, message.uid)) {
                skipped_disk++;
                if (skipped_disk % 128 == 0) {
                    Idle.add (prefetch_recent.callback);
                    yield;
                }
                continue;
            }

            try {
                yield enter_camel (false);
                ulong parent_id = 0;
                uint timeout_id = 0;
                var timed = bound_cancellable (cancellable, 45, out parent_id, out timeout_id);
                try {
                    /* Full MIME (body + attachments) into Camel’s on-disk cache. */
                    yield camel_folder.synchronize_message (message.uid, Priority.LOW, timed);
                    stored++;
                } finally {
                    unbind_cancellable (cancellable, parent_id, timeout_id);
                    leave_camel (false);
                }
            } catch (Error e) {
                if (e is IOError.CANCELLED)
                    throw e;
            }

            /* Let send / Inbox refresh take Camel before the next download. */
            if (this.high_refresh_waiters > 0)
                break;

            Idle.add (prefetch_recent.callback);
            yield;
        }

        var reached_end = i >= (int) listed.length
            || (cutoff > 0 && i < (int) listed.length && listed[i].date > 0 && listed[i].date < cutoff);
        /* If we paused for a high-priority waiter, resume later from here. */
        var paused_for_priority = this.high_refresh_waiters > 0 && !reached_end
            && (cancellable == null || !cancellable.is_cancelled ());
        var next_cursor = reached_end ? 0 : i;
        this.prefetch_cursor.set (cursor_key, next_cursor);
        schedule_prefetch_cursor_save ();

        if (stored > 0 || skipped_disk > 0 || start > 0) {
            Utils.sync_log ("prefetch “%s” done %s from-server=%u skipped-disk=%u cursor=%d/%u%s".printf (
                folder.name,
                Utils.sync_ms (t0),
                stored,
                skipped_disk,
                next_cursor,
                listed.length,
                paused_for_priority ? " (paused for priority)" : (reached_end ? " (window complete)" : "")
            ));
        }

        /* Camel/SQLite and glibc keep arenas warm across thousands of MIME parses. */
        Camel.DB.release_cache_memory ();
        trim_process_heap ();
        /* Signal caller to requeue when more work remains (chunk full or paused). */
        if (paused_for_priority && stored < PREFETCH_NETWORK_CHUNK)
            return PREFETCH_NETWORK_CHUNK;
        return stored;
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
        for (uint i = 0; i < keys.length; i++)
            this.prefetch_cursor.remove (keys[i]);
        schedule_prefetch_cursor_save ();
    }

    private static string prefetch_cursor_key (Account account, Folder folder) {
        var account_id = account.source_uid ?? account.uid;
        var account_safe = Checksum.compute_for_string (ChecksumType.SHA256, account_id);
        var folder_safe = Checksum.compute_for_string (ChecksumType.SHA256, folder.full_name);
        return "%s:%s".printf (account_safe, folder_safe);
    }

    public static string prefetch_cursor_cache_dir () {
        return Path.build_filename (Environment.get_user_cache_dir (), "letter", "prefetch-cursors");
    }

    public static string prefetch_cursor_cache_file () {
        return Path.build_filename (prefetch_cursor_cache_dir (), "cursors");
    }

    private bool prefetch_cursors_loaded = false;
    private uint prefetch_cursor_save_source = 0;

    private void ensure_prefetch_cursors_loaded () {
        if (this.prefetch_cursors_loaded)
            return;
        this.prefetch_cursors_loaded = true;
        var path = prefetch_cursor_cache_file ();
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
            debug ("Could not read prefetch cursors: %s", e.message);
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

    public void flush_prefetch_progress () {
        if (this.prefetch_cursor_save_source != 0) {
            Source.remove (this.prefetch_cursor_save_source);
            this.prefetch_cursor_save_source = 0;
        }
        if (this.prefetch_cursors_loaded)
            save_prefetch_cursors ();
    }

    private void save_prefetch_cursors () {
        try {
            File.new_for_path (prefetch_cursor_cache_dir ()).make_directory_with_parents ();
        } catch (Error e) {
            if (!(e is IOError.EXISTS)) {
                debug ("Could not create prefetch cursor dir: %s", e.message);
                return;
            }
        }

        var key = new KeyFile ();
        this.prefetch_cursor.foreach ((cursor_key, value) => {
            key.set_integer ("cursors", cursor_key, value);
        });
        try {
            key.save_to_file (prefetch_cursor_cache_file ());
        } catch (Error e) {
            debug ("Could not write prefetch cursors: %s", e.message);
        }
    }

    private static void delete_prefetch_cursor_file () {
        try {
            File.new_for_path (prefetch_cursor_cache_file ()).delete ();
        } catch (Error e) {
            if (!(e is IOError.NOT_FOUND))
                debug ("Could not delete prefetch cursors: %s", e.message);
        }
    }

    private static bool message_body_file_exists (Camel.Folder camel_folder, string uid) {
        try {
            var path = camel_folder.get_filename (uid);
            return path != null && path.length > 0 && FileUtils.test (path, FileTest.IS_REGULAR);
        } catch (Error e) {
            return false;
        }
    }

    [CCode (cname = "malloc_trim")]
    private static extern int malloc_trim (size_t pad);

    private static void trim_process_heap () {
        malloc_trim (0);
    }

    /* Drop full bodies older than the configured window. Headers stay in the
     * folder summary so search and the message list keep working. */
    public async uint prune_stale_bodies (
        Account account,
        Folder folder,
        GenericArray<Message> listed,
        int days,
        Cancellable? cancellable = null
    ) throws Error {
        if (days <= 0)
            return 0;

        var cutoff = body_cache_cutoff (days);
        if (cutoff <= 0)
            return 0;

        var camel_folder = yield open_camel_folder (account, folder, null);
        uint removed = 0;
        var t0 = Utils.sync_tick ();

        for (uint i = 0; i < listed.length; i++) {
            if (cancellable != null && cancellable.is_cancelled ())
                break;

            var message = listed[i];
            if (message.date <= 0 || message.date >= cutoff) {
                if (i % 64 == 63) {
                    Idle.add (prune_stale_bodies.callback);
                    yield;
                }
                continue;
            }

            drop_body (account, folder, message.uid);
            if (message_from_local_cache (camel_folder, message.uid) == null) {
                if (i % 32 == 31) {
                    Idle.add (prune_stale_bodies.callback);
                    yield;
                }
                continue;
            }

            if (yield drop_disk_body (camel_folder, message.uid, cancellable))
                removed++;

            Idle.add (prune_stale_bodies.callback);
            yield;
        }

        if (removed > 0) {
            Utils.sync_log ("prune “%s” removed %u bodies older than %d days %s".printf (
                folder.name,
                removed,
                days,
                Utils.sync_ms (t0)
            ));
        }
        return removed;
    }

    private static int64 body_cache_cutoff (int days) {
        if (days <= 0)
            return 0;
        return new DateTime.now_local ().add_days (-days).to_unix ();
    }

    private async bool drop_disk_body (
        Camel.Folder camel_folder,
        string uid,
        Cancellable? cancellable
    ) {
        try {
            var path = camel_folder.get_filename (uid);
            if (path != null && path.length > 0) {
                var file = File.new_for_path (path);
                if (file.query_exists ()) {
                    file.delete ();
                    return true;
                }
            }
        } catch (Error e) {
            debug ("Could not delete cached body file for %s: %s", uid, e.message);
        }

        try {
            yield enter_camel (false);
            try {
                yield camel_folder.purge_message_cache (uid, uid, Priority.LOW, cancellable);
                return true;
            } finally {
                leave_camel (false);
            }
        } catch (Error e) {
            debug ("Could not purge cached body for %s: %s", uid, e.message);
        }
        return false;
    }

    public async string move_message (Account account, Folder from, string uid, Folder destination, Cancellable? cancellable = null) throws Error {
        var source_folder = yield open_camel_folder (account, from, cancellable);
        var dest_folder = yield open_camel_folder (account, destination, cancellable);
        yield capture_local_body (account, from, uid, source_folder);
        var uids = new GenericArray<string> ();
        uids.add (uid);
#if HAVE_CAMEL_3_58
        GenericArray<weak string>? transferred = null;
#else
        GenericArray<string>? transferred = null;
#endif
        yield enter_camel (true);
        try {
            freeze_folders_for_transfer (source_folder, dest_folder);
            try {
                var xfer_t0 = Utils.sync_tick ();
                yield source_folder.transfer_messages_to (uids, dest_folder, true, Priority.DEFAULT, cancellable, out transferred);
                Utils.sync_log ("move Graph transfer “%s” → “%s” 1 uid %s".printf (
                    from.name,
                    destination.name,
                    Utils.sync_ms (xfer_t0)
                ));
            } finally {
                thaw_folders_for_transfer (source_folder, dest_folder);
            }
        } finally {
            leave_camel (true);
        }
        var new_uid = uid;
        if (transferred != null && transferred.length > 0 && transferred[0] != null && transferred[0].length > 0)
            new_uid = transferred[0];
        rekey_body (account, from, uid, destination, new_uid);
        apply_camel_counts (from, source_folder);
        apply_camel_counts (destination, dest_folder);
        return new_uid;
    }

    public async string copy_message (Account account, Folder from, string uid, Folder destination, Cancellable? cancellable = null) throws Error {
        var source_folder = yield open_camel_folder (account, from, cancellable);
        var dest_folder = yield open_camel_folder (account, destination, cancellable);
        var uids = new GenericArray<string> ();
        uids.add (uid);
#if HAVE_CAMEL_3_58
        GenericArray<weak string>? transferred = null;
#else
        GenericArray<string>? transferred = null;
#endif
        yield enter_camel (true);
        try {
            freeze_folders_for_transfer (source_folder, dest_folder);
            try {
                var xfer_t0 = Utils.sync_tick ();
                yield source_folder.transfer_messages_to (uids, dest_folder, false, Priority.DEFAULT, cancellable, out transferred);
                Utils.sync_log ("copy Graph transfer “%s” → “%s” 1 uid %s".printf (
                    from.name,
                    destination.name,
                    Utils.sync_ms (xfer_t0)
                ));
            } finally {
                thaw_folders_for_transfer (source_folder, dest_folder);
            }
        } finally {
            leave_camel (true);
        }
        var new_uid = uid;
        if (transferred != null && transferred.length > 0 && transferred[0] != null && transferred[0].length > 0)
            new_uid = transferred[0];
        apply_camel_counts (from, source_folder);
        apply_camel_counts (destination, dest_folder);
        return new_uid;
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

        /* Merge into the in-flight job or a queued same-route job so 30
         * archives stay one Graph workload, not N serial jobs. */
        if (this.transfer_flush_current != null
            && transfer_jobs_mergeable (this.transfer_flush_current, account, from, destination, true)) {
            merge_transfer_uids (this.transfer_flush_current, uids, messages);
            Utils.sync_log ("move flush merged “%s” → “%s” now %u messages".printf (
                from.name,
                destination.name,
                this.transfer_flush_current.uids.length
            ));
            schedule_mutation_registry_save ();
            return;
        }
        for (uint i = 0; i < this.transfer_flush_queue.length; i++) {
            var existing = this.transfer_flush_queue[i];
            if (!transfer_jobs_mergeable (existing, account, from, destination, true))
                continue;
            merge_transfer_uids (existing, uids, messages);
            Utils.sync_log ("move flush merged “%s” → “%s” now %u messages".printf (
                from.name,
                destination.name,
                existing.uids.length
            ));
            schedule_mutation_registry_save ();
            return;
        }

        var job = new TransferFlushJob () {
            account = account,
            from = from,
            destination = destination,
            uids = uids,
            messages = messages,
            delete_original = true,
            chunk_size = TRANSFER_CHUNK_START,
        };
        bump_transfer_pending (account, from, 1);
        if (from.full_name != destination.full_name)
            bump_transfer_pending (account, destination, 1);
        this.transfer_flush_queue.add (job);
        Utils.sync_log ("move flush deferred “%s” → “%s” %u messages".printf (
            from.name,
            destination.name,
            uids.length
        ));
        schedule_mutation_registry_save ();
    }

    /* Drop UIDs from a queued (not yet flushing) move — used by Undo. */
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

        for (uint i = 0; i < this.transfer_flush_queue.length; i++) {
            var job = this.transfer_flush_queue[i];
            if (!transfer_jobs_mergeable (job, account, from, destination, delete_original))
                continue;

            var kept_uids = new GenericArray<string> ();
            GenericArray<Message>? kept_messages = null;
            if (job.messages != null)
                kept_messages = new GenericArray<Message> ();
            for (uint u = 0; u < job.uids.length; u++) {
                if (drop.contains (job.uids[u]))
                    continue;
                kept_uids.add (job.uids[u]);
                if (kept_messages != null && job.messages != null && u < job.messages.length)
                    kept_messages.add (job.messages[u]);
            }
            if (kept_uids.length == job.uids.length)
                return;

            if (kept_uids.length == 0) {
                this.transfer_flush_queue.remove_index (i);
                bump_transfer_pending (account, from, -1);
                if (from.full_name != destination.full_name)
                    bump_transfer_pending (account, destination, -1);
                Utils.sync_log ("move flush cancelled “%s” → “%s”".printf (from.name, destination.name));
            } else {
                job.uids = kept_uids;
                job.messages = kept_messages;
                Utils.sync_log ("move flush undo trimmed “%s” → “%s” now %u".printf (
                    from.name,
                    destination.name,
                    kept_uids.length
                ));
            }
            schedule_mutation_registry_save ();
            return;
        }
    }

    /* Copy without removing from source (Gmail Important label). Deferred like moves. */
    public void enqueue_copy_messages (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        GenericArray<Message>? messages
    ) {
        if (uids.length == 0)
            return;

        if (this.transfer_flush_current != null
            && transfer_jobs_mergeable (this.transfer_flush_current, account, from, destination, false)) {
            merge_transfer_uids (this.transfer_flush_current, uids, messages);
            Utils.sync_log ("copy flush merged “%s” → “%s” now %u messages".printf (
                from.name,
                destination.name,
                this.transfer_flush_current.uids.length
            ));
            schedule_mutation_registry_save ();
            return;
        }
        for (uint i = 0; i < this.transfer_flush_queue.length; i++) {
            var existing = this.transfer_flush_queue[i];
            if (!transfer_jobs_mergeable (existing, account, from, destination, false))
                continue;
            merge_transfer_uids (existing, uids, messages);
            Utils.sync_log ("copy flush merged “%s” → “%s” now %u messages".printf (
                from.name,
                destination.name,
                existing.uids.length
            ));
            schedule_mutation_registry_save ();
            return;
        }

        var job = new TransferFlushJob () {
            account = account,
            from = from,
            destination = destination,
            uids = uids,
            messages = messages,
            delete_original = false,
            chunk_size = TRANSFER_CHUNK_START,
        };
        bump_transfer_pending (account, from, 1);
        if (from.full_name != destination.full_name)
            bump_transfer_pending (account, destination, 1);
        this.transfer_flush_queue.add (job);
        Utils.sync_log ("copy flush deferred “%s” → “%s” %u messages".printf (
            from.name,
            destination.name,
            uids.length
        ));
        schedule_mutation_registry_save ();
    }

    private static bool transfer_jobs_mergeable (
        TransferFlushJob existing,
        Account account,
        Folder from,
        Folder destination,
        bool delete_original
    ) {
        if (existing.delete_original != delete_original)
            return false;
        if ((existing.account.source_uid ?? existing.account.uid)
            != (account.source_uid ?? account.uid))
            return false;
        if (existing.from.full_name != from.full_name)
            return false;
        if (existing.destination.full_name != destination.full_name)
            return false;
        return true;
    }

    private static void merge_transfer_uids (
        TransferFlushJob job,
        GenericArray<string> uids,
        GenericArray<Message>? messages
    ) {
        /* New UIDs on a parked route should be eligible on the next wave. */
        job.parked_until = 0;
        var seen = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < job.uids.length; i++)
            seen.set (job.uids[i], 1);
        for (uint i = 0; i < uids.length; i++) {
            if (seen.contains (uids[i]))
                continue;
            seen.set (uids[i], 1);
            job.uids.add (uids[i]);
            if (messages != null && i < messages.length) {
                if (job.messages == null)
                    job.messages = new GenericArray<Message> ();
                job.messages.add (messages[i]);
            }
        }
    }

    public uint pending_transfer_count {
        get {
            uint n = 0;
            for (uint i = 0; i < this.transfer_flush_queue.length; i++)
                n += this.transfer_flush_queue[i].uids.length;
            if (this.transfer_flush_current != null
                && this.transfer_flush_done < this.transfer_flush_current.uids.length)
                n += this.transfer_flush_current.uids.length - this.transfer_flush_done;
            return n;
        }
    }

    public uint pending_transfer_jobs {
        get {
            return this.transfer_flush_queue.length
                + (this.transfer_flush_current != null ? 1u : 0u);
        }
    }

    /* Push deferred flag/move/copy jobs (sync-interval / F5 / quit / startup).
     * Flag and transfer pumps run independently so a parked Archive move does
     * not stall SEEN / Trash. */
    public void flush_pending_local_changes () {
        clear_expired_transfer_parks ();
        if (this.flag_flush_queue.length > 0)
            Utils.sync_log ("flushing deferred flags (%u queue)".printf (this.flag_flush_queue.length));
        if (this.transfer_flush_queue.length > 0
            || this.transfer_flush_current != null)
            Utils.sync_log ("flushing deferred transfers (%u queue)".printf (
                this.transfer_flush_queue.length
                + (this.transfer_flush_current != null ? 1u : 0u)
            ));
        pump_flag_flush.begin ();
        pump_transfer_flush.begin ();
    }

    public bool has_queued_mutations () {
        return this.transfer_flush_queue.length > 0
            || this.transfer_flush_current != null
            || this.flag_flush_queue.length > 0
            || this.flag_flush_latest.size () > 0;
    }

    /* True when flags or non-parked transfers still need Camel before Inbox
     * refresh. Parked heavy Archive jobs must not defer mail-check. */
    public bool has_blocking_local_flushes () {
        if (this.flag_flush_running
            || this.flag_flush_queue.length > 0
            || this.flag_flush_latest.size () > 0)
            return true;
        if (this.transfer_flush_running)
            return true;
        for (uint i = 0; i < this.transfer_flush_queue.length; i++) {
            if (!transfer_job_is_parked (this.transfer_flush_queue[i]))
                return true;
        }
        return false;
    }

    private void clear_expired_transfer_parks () {
        for (uint i = 0; i < this.transfer_flush_queue.length; i++) {
            var job = this.transfer_flush_queue[i];
            if (job.parked_until > 0 && job.parked_until <= Utils.sync_tick ()) {
                Utils.sync_log ("move flush park expired “%s” → “%s” (%u uids)".printf (
                    job.from.name,
                    job.destination.name,
                    job.uids.length
                ));
                job.parked_until = 0;
            }
        }
    }

    /* Clear leftover parks so the next flush wave can drain moves. */
    public void unpark_heavy_transfers () {
        for (uint i = 0; i < this.transfer_flush_queue.length; i++) {
            var job = this.transfer_flush_queue[i];
            if (job.parked_until <= 0)
                continue;
            job.parked_until = 0;
            Utils.sync_log ("move flush unpark “%s” → “%s” (%u uids)".printf (
                job.from.name,
                job.destination.name,
                job.uids.length
            ));
        }
    }

    /* Drain the soft-mutation registry, waiting up to @seconds. Returns true
     * when the queues are empty. On timeout the on-disk registry is kept. */
    public async bool flush_pending_local_changes_with_timeout (uint seconds) {
        if (!has_queued_mutations ()) {
            clear_mutation_registry_file ();
            return true;
        }

        this.flush_force = true;
        unpark_heavy_transfers ();
        flush_pending_local_changes ();
        var deadline = Utils.sync_tick () + (int64) seconds * TimeSpan.SECOND;
        while (has_queued_mutations () || this.flag_flush_running || this.transfer_flush_running) {
            if (Utils.sync_tick () >= deadline) {
                Utils.sync_log ("mutation registry flush timed out after %us — keeping disk file".printf (seconds));
                persist_mutation_registry_now ();
                return false;
            }
            Timeout.add (100, flush_pending_local_changes_with_timeout.callback);
            yield;
        }
        clear_mutation_registry_file ();
        Utils.sync_log ("mutation registry flush ok");
        return true;
    }

    public static string mutation_registry_dir () {
        return Path.build_filename (Environment.get_user_data_dir (), "letter", "mutation-registry");
    }

    public static string mutation_registry_file () {
        return Path.build_filename (mutation_registry_dir (), "pending");
    }

    public void schedule_mutation_registry_save () {
        /* Restart the debounce so the last in-flight snapshot wins — otherwise
         * a mid-flush save (e.g. 5/7 left) can stick on disk after the job
         * finishes and nothing schedules a clear. */
        if (this.mutation_registry_save_source != 0)
            Source.remove (this.mutation_registry_save_source);
        this.mutation_registry_save_source = Timeout.add (400, () => {
            this.mutation_registry_save_source = 0;
            persist_mutation_registry_now ();
            return Source.REMOVE;
        });
    }

    public void persist_mutation_registry_now () {
        if (this.mutation_registry_save_source != 0) {
            Source.remove (this.mutation_registry_save_source);
            this.mutation_registry_save_source = 0;
        }
        if (!has_queued_mutations ()) {
            clear_mutation_registry_file ();
            return;
        }

        try {
            File.new_for_path (mutation_registry_dir ()).make_directory_with_parents ();
        } catch (Error e) {
            if (!(e is IOError.EXISTS)) {
                warning ("Could not create mutation registry dir: %s", e.message);
                return;
            }
        }

        var key = new KeyFile ();
        key.set_integer ("meta", "version", 1);
        uint transfer_n = 0;
        if (this.transfer_flush_current != null
            && this.transfer_flush_done < this.transfer_flush_current.uids.length) {
            write_transfer_job_to_keyfile (key, "transfer-%u".printf (transfer_n),
                this.transfer_flush_current, this.transfer_flush_done);
            transfer_n++;
        }
        for (uint i = 0; i < this.transfer_flush_queue.length; i++) {
            var job = this.transfer_flush_queue[i];
            if (job.uids.length == 0)
                continue;
            write_transfer_job_to_keyfile (key, "transfer-%u".printf (transfer_n),
                job, 0);
            transfer_n++;
        }
        key.set_integer ("meta", "transfers", (int) transfer_n);

        uint flag_n = 0;
        var seen_flag = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < this.flag_flush_queue.length; i++) {
            var job = this.flag_flush_queue[i];
            var fk = flag_flush_key (job.account, job.folder);
            if (this.flag_flush_latest.get (fk) != job)
                continue;
            if (seen_flag.contains (fk))
                continue;
            seen_flag.set (fk, 1);
            write_flag_job_to_keyfile (key, "flag-%u".printf (flag_n), job);
            flag_n++;
        }
        key.set_integer ("meta", "flags", (int) flag_n);

        if (transfer_n == 0 && flag_n == 0) {
            clear_mutation_registry_file ();
            return;
        }

        try {
            key.save_to_file (mutation_registry_file ());
            Utils.sync_log ("mutation registry saved (%u transfers, %u flags)".printf (transfer_n, flag_n));
        } catch (Error e) {
            warning ("Could not write mutation registry: %s", e.message);
        }
    }

    private static void write_transfer_job_to_keyfile (
        KeyFile key,
        string group,
        TransferFlushJob job,
        uint from_index
    ) {
        var account_id = job.account.source_uid ?? job.account.uid;
        key.set_string (group, "account", account_id);
        key.set_string (group, "from", job.from.full_name);
        key.set_string (group, "from_name", job.from.name);
        key.set_string (group, "destination", job.destination.full_name);
        key.set_string (group, "destination_name", job.destination.name);
        key.set_boolean (group, "delete_original", job.delete_original);
        key.set_integer (group, "chunk_size", (int) (job.chunk_size > 0 ? job.chunk_size : TRANSFER_CHUNK_START));
        var uids = new string[0];
        for (uint i = from_index; i < job.uids.length; i++)
            uids += job.uids[i];
        key.set_string_list (group, "uids", uids);
    }

    private static void write_flag_job_to_keyfile (KeyFile key, string group, FlagFlushJob job) {
        var account_id = job.account.source_uid ?? job.account.uid;
        key.set_string (group, "account", account_id);
        key.set_string (group, "folder", job.folder.full_name);
        key.set_string (group, "folder_name", job.folder.name);
        key.set_boolean (group, "expunge", job.expunge);
        var uids = new string[job.uids.length];
        for (uint i = 0; i < job.uids.length; i++)
            uids[i] = job.uids[i];
        key.set_string_list (group, "uids", uids);
    }

    private void clear_mutation_registry_file () {
        var path = mutation_registry_file ();
        if (!FileUtils.test (path, FileTest.IS_REGULAR))
            return;
        if (FileUtils.remove (path) == 0)
            Utils.sync_log ("mutation registry cleared");
        else
            debug ("Could not remove mutation registry at %s", path);
    }

    /* Load soft moves/flags from disk into the in-memory queues. */
    public uint load_mutation_registry () {
        if (this.mutation_registry_loaded)
            return 0;
        this.mutation_registry_loaded = true;
        var path = mutation_registry_file ();
        if (!FileUtils.test (path, FileTest.IS_REGULAR))
            return 0;

        KeyFile key;
        try {
            key = new KeyFile ();
            key.load_from_file (path, KeyFileFlags.NONE);
        } catch (Error e) {
            warning ("Could not read mutation registry: %s", e.message);
            return 0;
        }

        uint loaded = 0;
        try {
            var transfer_n = key.has_group ("meta") ? key.get_integer ("meta", "transfers") : 0;
            for (int i = 0; i < transfer_n; i++) {
                var group = "transfer-%d".printf (i);
                if (!key.has_group (group))
                    continue;
                var job = read_transfer_job_from_keyfile (key, group);
                if (job == null || job.uids.length == 0)
                    continue;
                this.transfer_flush_queue.add (job);
                bump_transfer_pending (job.account, job.from, 1);
                if (job.from.full_name != job.destination.full_name)
                    bump_transfer_pending (job.account, job.destination, 1);
                loaded++;
            }
            var flag_n = key.has_group ("meta") ? key.get_integer ("meta", "flags") : 0;
            for (int i = 0; i < flag_n; i++) {
                var group = "flag-%d".printf (i);
                if (!key.has_group (group))
                    continue;
                var job = read_flag_job_from_keyfile (key, group);
                if (job == null || job.uids.length == 0)
                    continue;
                var fk = flag_flush_key (job.account, job.folder);
                this.flag_flush_latest.set (fk, job);
                this.flag_flush_queue.add (job);
                loaded++;
            }
        } catch (Error e) {
            warning ("Could not parse mutation registry: %s", e.message);
        }

        if (loaded > 0)
            Utils.sync_log ("mutation registry loaded (%u jobs)".printf (loaded));
        return loaded;
    }

    private TransferFlushJob? read_transfer_job_from_keyfile (KeyFile key, string group) throws Error {
        var account = account_from_source_uid (key.get_string (group, "account"));
        if (account == null)
            return null;
        var from = folder_stub (key.get_string (group, "from"),
            key.has_key (group, "from_name") ? key.get_string (group, "from_name") : null);
        var destination = folder_stub (key.get_string (group, "destination"),
            key.has_key (group, "destination_name") ? key.get_string (group, "destination_name") : null);
        var uids = new GenericArray<string> ();
        foreach (var uid in key.get_string_list (group, "uids")) {
            if (uid != null && uid.length > 0)
                uids.add (uid);
        }
        return new TransferFlushJob () {
            account = account,
            from = from,
            destination = destination,
            uids = uids,
            messages = null,
            delete_original = key.get_boolean (group, "delete_original"),
            chunk_size = (uint) int.max (1, key.get_integer (group, "chunk_size")),
        };
    }

    private FlagFlushJob? read_flag_job_from_keyfile (KeyFile key, string group) throws Error {
        var account = account_from_source_uid (key.get_string (group, "account"));
        if (account == null)
            return null;
        var folder = folder_stub (key.get_string (group, "folder"),
            key.has_key (group, "folder_name") ? key.get_string (group, "folder_name") : null);
        var uids = new GenericArray<string> ();
        foreach (var uid in key.get_string_list (group, "uids")) {
            if (uid != null && uid.length > 0)
                uids.add (uid);
        }
        return new FlagFlushJob () {
            account = account,
            folder = folder,
            uids = uids,
            expunge = key.get_boolean (group, "expunge"),
        };
    }

    private Account? account_from_source_uid (string uid) {
        if (uid.length == 0)
            return null;
        var source = this.registry.ref_source (uid);
        if (source == null || !source.has_extension (E.SOURCE_EXTENSION_MAIL_ACCOUNT))
            return null;
        var mail_account = (E.SourceMailAccount) source.get_extension (E.SOURCE_EXTENSION_MAIL_ACCOUNT);
        var backend_name = mail_account.dup_backend_name ();
        return new Account () {
            uid = uid,
            source_uid = uid,
            display_name = source.display_name ?? uid,
            has_mail = true,
            enabled = source.enabled,
            backend_name = backend_name,
            kind = AccountKind.from_provider (null, backend_name),
        };
    }

    private static Folder folder_stub (string full_name, string? name) {
        var folder = new Folder () {
            full_name = full_name,
            name = (name != null && name.length > 0) ? name : full_name,
        };
        apply_folder_display_name (folder);
        return folder;
    }

    /* Walk queued soft-moves so the UI can re-hide source UIDs after restart. */
    public void foreach_queued_move_hide (QueuedMoveHideFunc func) {
        if (this.transfer_flush_current != null) {
            var job = this.transfer_flush_current;
            for (uint i = this.transfer_flush_done; i < job.uids.length; i++)
                func (job.account, job.from, job.uids[i]);
        }
        for (uint j = 0; j < this.transfer_flush_queue.length; j++) {
            var job = this.transfer_flush_queue[j];
            for (uint i = 0; i < job.uids.length; i++)
                func (job.account, job.from, job.uids[i]);
        }
    }

    /* True while a flush worker is actually running — for status UI.
     * Queued-but-idle jobs (waiting for the sync timer) must not light the bar. */
    public bool has_active_local_flushes () {
        return this.flag_flush_running
            || this.transfer_flush_running
            || this.transfer_flush_current != null;
    }

    public bool has_pending_local_flushes () {
        return has_active_local_flushes ()
            || this.transfer_pending.size () > 0
            || this.flag_flush_latest.size () > 0;
    }

    /* Wait until blocking moves/flags reach the server before Inbox refresh,
     * otherwise Camel still lists archived mail and Letter notifies them as new.
     * Parked heavy Archive jobs do not block — they retry on the next wave. */
    public async void flush_pending_local_changes_async () {
        this.flush_force = true;
        flush_pending_local_changes ();
        var waited = 0;
        while (has_blocking_local_flushes ()) {
            if (waited == 0)
                Utils.sync_log ("waiting for local flush before mail check");
            waited++;
            if (waited > 1200) {
                /* Keep flush_force so moves stay high-priority; caller defers
                 * Inbox refresh while blocking work remains. */
                Utils.sync_log ("local flush wait timed out — keeping flush priority (%u transfers)".printf (
                    this.transfer_flush_queue.length
                ));
                break;
            }
            Timeout.add (50, flush_pending_local_changes_async.callback);
            yield;
        }
        if (waited > 0 && !has_blocking_local_flushes ()) {
            Utils.sync_log ("local flush settled after %d ms".printf (waited * 50));
            this.flush_force = false;
        } else if (!has_blocking_local_flushes ()) {
            this.flush_force = false;
        }
    }

    /* Push DELETED flags then optionally Camel.Folder.expunge.
     * synchronize(expunge=true) alone is a no-op on Microsoft 365 Graph.
     * On Graph, Folder.expunge hard-deletes *every* UID in Trash — so selective
     * deletes must synchronize only. Empty Trash still needs expunge.
     * ErrorItemNotFound means Graph already dropped the item — treat as success. */
    private async void push_deleted_and_expunge (
        Camel.Folder camel_folder,
        string folder_name,
        uint count,
        bool high,
        bool do_expunge,
        Cancellable? cancellable
    ) throws Error {
        yield enter_camel (high);
        try {
            var priority = high ? Priority.DEFAULT : Priority.LOW;
            try {
                yield camel_folder.synchronize (false, priority, cancellable);
                if (do_expunge)
                    yield camel_folder.expunge (priority, cancellable);
            } catch (Error e) {
                if (is_missing_on_server (e)) {
                    Utils.sync_log ("purge “%s” %u messages — already gone on server".printf (
                        folder_name,
                        count
                    ));
                    return;
                }
                throw e;
            }
            Utils.sync_log ("purge “%s” %u messages (%s)".printf (
                folder_name,
                count,
                do_expunge ? "sync+expunge" : "sync"
            ));
        } finally {
            leave_camel (high);
        }
    }

    /* evolution-ews only hard-deletes / resolves "deleteditems" when the Camel
     * store summary has TYPE_TRASH (and TYPE_JUNK for Junk). Graph folder delta
     * sometimes leaves those bits unset (Flags=NOCHILDREN only) — then expunge
     * is a no-op and soft-delete cannot find Trash, so mail resurrects. */
    private async void ensure_m365_folder_types (Account account) throws Error {
        if (!backend_saves_sent_on_server (account))
            return;
        var uid = account.source_uid;
        if (uid == null || uid.length == 0)
            return;
        if (this.m365_folder_types_ok.get (uid))
            return;

        var tree_path = Path.build_filename (mail_cache_root (), uid, "folder-tree");
        if (!FileUtils.test (tree_path, FileTest.IS_REGULAR)) {
            this.m365_folder_types_ok.set (uid, true);
            return;
        }

        uint patched = 0;
        try {
            patched = patch_m365_folder_tree_types (tree_path);
        } catch (Error e) {
            warning ("Could not repair M365 folder types: %s", e.message);
            return;
        }

        /* Always reload once per account/session so an already-patched
         * folder-tree on disk replaces a stale in-memory summary (Flags
         * without TYPE_TRASH make Graph purge a silent no-op). */
        if (patched > 0)
            Utils.sync_log ("repaired %u M365 special-folder type flag(s) — reloading store".printf (patched));
        else
            Utils.sync_log ("reloading M365 store to apply special-folder type flags");

        unwatch_account_folders (uid);
        var service = ref_service (uid);
        if (service != null) {
            try {
                var offline = service as Camel.OfflineStore;
                if (offline != null && offline.get_online ())
                    yield offline.set_online (false, Priority.DEFAULT, null);
                else if (service.get_connection_status () == Camel.ServiceConnectionStatus.CONNECTED)
                    yield service.disconnect (true, Priority.DEFAULT, null);
            } catch (Error e) {
                debug ("Could not disconnect before M365 type reload: %s", e.message);
            }
            remove_service (service);
        }
        yield open_store (account, null, true);
        this.m365_folder_types_ok.set (uid, true);
    }

    private static uint patch_m365_folder_tree_types (string tree_path) throws Error {
        var key = new KeyFile ();
        key.load_from_file (tree_path, KeyFileFlags.NONE);
        var groups = key.get_groups ();
        uint patched = 0;
        foreach (unowned string group in groups) {
            if (group.has_prefix ("#"))
                continue;
            if (!key.has_key (group, "DisplayName"))
                continue;
            var display = key.get_string (group, "DisplayName");
            var kind = FolderKind.from_flags (0, display, display);
            uint32 type_bit = 0;
            switch (kind) {
                case FolderKind.INBOX:
                    type_bit = (uint32) Camel.FolderInfoFlags.TYPE_INBOX;
                    break;
                case FolderKind.OUTBOX:
                    type_bit = (uint32) Camel.FolderInfoFlags.TYPE_OUTBOX;
                    break;
                case FolderKind.TRASH:
                    type_bit = (uint32) Camel.FolderInfoFlags.TYPE_TRASH;
                    break;
                case FolderKind.JUNK:
                    type_bit = (uint32) Camel.FolderInfoFlags.TYPE_JUNK;
                    break;
                case FolderKind.SENT:
                    type_bit = (uint32) Camel.FolderInfoFlags.TYPE_SENT;
                    break;
                case FolderKind.DRAFTS:
                    type_bit = (uint32) Camel.FolderInfoFlags.TYPE_DRAFTS;
                    break;
                case FolderKind.ARCHIVE:
                case FolderKind.ALL:
                    type_bit = (uint32) Camel.FolderInfoFlags.TYPE_ARCHIVE;
                    break;
                default:
                    continue;
            }

            uint64 flags = 0;
            if (key.has_key (group, "Flags"))
                flags = key.get_uint64 (group, "Flags");
            var mask = (uint64) Folder.TYPE_MASK;
            if ((flags & mask) == type_bit)
                continue;
            flags = (flags & ~mask) | type_bit;
            key.set_uint64 (group, "Flags", flags);
            patched++;
        }
        if (patched > 0)
            key.save_to_file (tree_path);
        return patched;
    }

    public async void delete_message (Account account, Folder folder, string uid, Folder? trash, Cancellable? cancellable = null) throws Error {
        if (trash != null && folder.full_name != trash.full_name) {
            yield move_message (account, folder, uid, trash, cancellable);
            return;
        }

        yield ensure_m365_folder_types (account);
        if (backend_saves_sent_on_server (account) && folder.kind == FolderKind.JUNK) {
            var uids = new GenericArray<string> ();
            uids.add (uid);
            yield hard_delete_m365_junk (account, folder, uids, cancellable);
            if (folder.kind == FolderKind.DRAFTS)
                draft_removed (account, folder, uid);
            return;
        }

        /* Hard-delete (already in Trash, Drafts after send, or no Trash). */
        var camel_folder = yield open_camel_folder (account, folder, cancellable);
        camel_folder.set_message_flags (uid, Camel.MessageFlags.DELETED, Camel.MessageFlags.DELETED);
        drop_body (account, folder, uid);
        try {
            /* Graph Trash expunge wipes the whole folder — sync-only for one UID. */
            var do_expunge = !backend_saves_sent_on_server (account)
                || folder.kind != FolderKind.TRASH;
            yield push_deleted_and_expunge (camel_folder, folder.name, 1, true, do_expunge, cancellable);
        } catch (Error e) {
            warning ("Could not expunge deleted message: %s", e.message);
            throw e;
        }
        apply_camel_counts (folder, camel_folder);
        if (folder.kind == FolderKind.DRAFTS)
            draft_removed (account, folder, uid);
    }

    /* Mark deleted in the local Camel store only — server push waits for the
     * normal folder sync interval (routine soft-delete / flags). Draft revision
     * replace uses purge_replaced_draft instead so Microsoft 365 sees it now. */
    public async void delete_message_local (Account account, Folder folder, string uid) throws Error {
        var camel_folder = yield open_camel_folder (account, folder, null);
        camel_folder.set_message_flags (uid, Camel.MessageFlags.DELETED, Camel.MessageFlags.DELETED);
        drop_body (account, folder, uid);
        apply_camel_counts (folder, camel_folder);
        if (folder.kind == FolderKind.DRAFTS)
            draft_removed (account, folder, uid);
        /* Queue DELETED so the soft-deleted UID disappears on the server too. */
        var uids = new GenericArray<string> ();
        uids.add (uid);
        enqueue_flag_flush (account, folder, uids);
    }

    public async void delete_uids (Account account, Folder folder, GenericArray<string> uids, Folder? trash) throws Error {
        if (uids.length == 0)
            return;
        if (trash != null && folder.full_name != trash.full_name) {
            enqueue_move_messages (account, folder, trash, uids, null);
            return;
        }

        yield ensure_m365_folder_types (account);
        if (backend_saves_sent_on_server (account) && folder.kind == FolderKind.JUNK) {
            yield hard_delete_m365_junk (account, folder, uids, null);
            return;
        }

        var camel_folder = yield open_camel_folder (account, folder, null);
        camel_folder.freeze ();
        try {
            for (uint i = 0; i < uids.length; i++) {
                camel_folder.set_message_flags (
                    uids[i],
                    Camel.MessageFlags.DELETED,
                    Camel.MessageFlags.DELETED
                );
                drop_body (account, folder, uids[i]);
            }
        } finally {
            camel_folder.thaw ();
        }
        apply_camel_counts (folder, camel_folder);
        /* Hard-delete: Graph Trash uses sync only (expunge = empty entire Trash). */
        var do_expunge = !backend_saves_sent_on_server (account)
            || folder.kind != FolderKind.TRASH;
        yield push_deleted_and_expunge (camel_folder, folder.name, uids.length, true, do_expunge, null);
    }

    public async void empty_folder (Account account, Folder folder) throws Error {
        if (folder.is_virtual_view)
            return;

        yield ensure_m365_folder_types (account);
        var camel_folder = yield open_camel_folder (account, folder, null);
        var raw = folder_list_uids (camel_folder);
        if (raw.length == 0) {
            folder.unread = 0;
            folder.total = 0;
            return;
        }

        if (backend_saves_sent_on_server (account) && folder.kind == FolderKind.JUNK) {
            yield hard_delete_m365_junk (account, folder, raw, null);
            folder.unread = 0;
            folder.total = 0;
            Utils.sync_log ("empty “%s” %u messages done".printf (folder.name, raw.length));
            return;
        }

        camel_folder.freeze ();
        try {
            for (uint i = 0; i < raw.length; i++) {
                camel_folder.set_message_flags (
                    raw[i],
                    Camel.MessageFlags.DELETED,
                    Camel.MessageFlags.DELETED
                );
                drop_body (account, folder, raw[i]);
            }
        } finally {
            camel_folder.thaw ();
        }
        folder.unread = 0;
        folder.total = 0;
        /* Empty Trash: always expunge after sync (IMAP + Graph Trash). */
        yield push_deleted_and_expunge (camel_folder, folder.name, raw.length, true, true, null);
        Utils.sync_log ("empty “%s” %u messages done".printf (folder.name, raw.length));
    }

    /* Graph Junk: DELETED+sync only soft-moves to Trash; expunge is a no-op.
     * Move into Trash then hard-delete there (sync without full-folder expunge). */
    private async void hard_delete_m365_junk (
        Account account,
        Folder junk,
        GenericArray<string> uids,
        Cancellable? cancellable
    ) throws Error {
        if (uids.length == 0)
            return;

        var store = yield open_store (account, cancellable, true);
        /* Prefer opening Trash by mailbox name. store.get_trash_folder() first
         * synchronizes every open folder and refreshes Trash — that races the
         * Junk purge and often surfaces ErrorItemNotFound toasts. */
        Camel.Folder? trash_camel = null;
        try {
            var folders = yield list_folders (account, cancellable, false);
            for (uint i = 0; i < folders.length; i++) {
                if (folders[i].kind != FolderKind.TRASH)
                    continue;
                trash_camel = yield open_camel_folder (account, folders[i], cancellable);
                break;
            }
        } catch (Error e) {
            debug ("Could not open Trash by name for Junk purge: %s", e.message);
        }
        if (trash_camel == null) {
            try {
                trash_camel = yield store.get_trash_folder (Priority.DEFAULT, cancellable);
            } catch (Error e) {
                warning ("M365 Trash folder unavailable for Junk purge: %s", e.message);
            }
        }
        if (trash_camel == null) {
            throw new IOError.NOT_FOUND (
                _("Could not locate Trash folder")
            );
        }

        var junk_camel = yield open_camel_folder (account, junk, cancellable);
#if HAVE_CAMEL_3_58
        GenericArray<weak string>? transferred = null;
#else
        GenericArray<string>? transferred = null;
#endif
        yield enter_camel (true);
        try {
            freeze_folders_for_transfer (junk_camel, trash_camel);
            try {
                try {
                    yield junk_camel.transfer_messages_to (
                        uids,
                        trash_camel,
                        true,
                        Priority.DEFAULT,
                        cancellable,
                        out transferred
                    );
                } catch (Error e) {
                    /* Partial Graph batches often end with ErrorItemNotFound for
                     * already-purged ids while the rest moved successfully. */
                    if (!is_missing_on_server (e))
                        throw e;
                    Utils.sync_log ("Junk→Trash transfer reported missing items — continuing purge");
                }
            } finally {
                thaw_folders_for_transfer (junk_camel, trash_camel);
            }
        } finally {
            leave_camel (true);
        }

        var purge = new GenericArray<string> ();
        if (transferred != null) {
            for (uint i = 0; i < transferred.length; i++) {
                if (transferred[i] != null && transferred[i].length > 0)
                    purge.add (transferred[i]);
            }
        }
        /* M365 often keeps the same Graph id across folders — purge those too. */
        if (purge.length == 0) {
            for (uint i = 0; i < uids.length; i++) {
                if (trash_camel.get_message_info (uids[i]) != null)
                    purge.add (uids[i]);
            }
        }
        if (purge.length == 0) {
            for (uint i = 0; i < uids.length; i++)
                drop_body (account, junk, uids[i]);
            apply_camel_counts (junk, junk_camel);
            Utils.sync_log ("purge Junk “%s” %u messages (moved to Trash)".printf (junk.name, uids.length));
            return;
        }

        trash_camel.freeze ();
        try {
            for (uint i = 0; i < purge.length; i++) {
                trash_camel.set_message_flags (
                    purge[i],
                    Camel.MessageFlags.DELETED,
                    Camel.MessageFlags.DELETED
                );
            }
        } finally {
            trash_camel.thaw ();
        }
        for (uint i = 0; i < uids.length; i++)
            drop_body (account, junk, uids[i]);
        try {
            yield push_deleted_and_expunge (
                trash_camel,
                trash_camel.get_full_display_name () ?? trash_camel.get_display_name () ?? "Trash",
                purge.length,
                true,
                false,
                cancellable
            );
        } catch (Error e) {
            if (!is_missing_on_server (e))
                throw e;
            Utils.sync_log ("purge Junk via Trash — already gone on server");
        }
        apply_camel_counts (junk, junk_camel);
    }

    public async void set_folder_seen (Account account, Folder folder, bool seen) throws Error {
        var camel_folder = yield open_camel_folder (account, folder, null);
        var raw = folder_list_uids (camel_folder);
        if (raw.length == 0)
            return;

        var uids = new GenericArray<string> ();
        camel_folder.freeze ();
        try {
            for (uint i = 0; i < raw.length; i++) {
                var flags = camel_folder.get_message_flags (raw[i]);
                var currently_seen = (flags & Camel.MessageFlags.SEEN) != 0;
                if (currently_seen == seen)
                    continue;

                camel_folder.set_message_flags (
                    raw[i],
                    Camel.MessageFlags.SEEN,
                    seen ? Camel.MessageFlags.SEEN : 0
                );
                uids.add (raw[i]);
            }
        } finally {
            camel_folder.thaw ();
        }
        apply_camel_counts (folder, camel_folder);
        Utils.sync_log ("mark folder “%s” %s: %u changed of %u".printf (
            folder.name,
            seen ? "read" : "unread",
            uids.length,
            raw.length
        ));
        if (uids.length == 0)
            return;
        enqueue_flag_flush (account, folder, uids);
    }

    public async void set_uids_seen (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        bool seen
    ) throws Error {
        if (uids.length == 0)
            return;

        var camel_folder = yield open_camel_folder (account, folder, null);
        var changed = new GenericArray<string> ();
        camel_folder.freeze ();
        try {
            for (uint i = 0; i < uids.length; i++) {
                var flags = camel_folder.get_message_flags (uids[i]);
                var currently_seen = (flags & Camel.MessageFlags.SEEN) != 0;
                if (currently_seen == seen)
                    continue;

                camel_folder.set_message_flags (
                    uids[i],
                    Camel.MessageFlags.SEEN,
                    seen ? Camel.MessageFlags.SEEN : 0
                );
                changed.add (uids[i]);
            }
        } finally {
            camel_folder.thaw ();
        }
        apply_camel_counts (folder, camel_folder);
        if (changed.length == 0)
            return;
        enqueue_flag_flush (account, folder, changed);
    }

    public async void set_uids_flagged (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        bool flagged
    ) throws Error {
        if (uids.length == 0 || folder.is_virtual_view)
            return;

        var camel_folder = yield open_camel_folder (account, folder, null);
        var changed = new GenericArray<string> ();
        camel_folder.freeze ();
        try {
            if (uses_outlook_flag_semantics (account)) {
                for (uint i = 0; i < uids.length; i++) {
                    var info = camel_folder.get_message_info (uids[i]);
                    if (info == null)
                        continue;
                    if (info_has_active_followup (info) == flagged)
                        continue;
                    if (flagged) {
                        /* Same tag Evolution uses when reading Graph follow-up flags. */
                        info.set_user_tag ("follow-up", "Follow-up");
                        info.set_user_tag ("completed-on", null);
                    } else {
                        info.set_user_tag ("follow-up", null);
                        info.set_user_tag ("completed-on", null);
                        info.set_user_tag ("due-by", null);
                        info.set_user_tag ("follow-up-start", null);
                    }
                    info.set_folder_flagged (true);
                    changed.add (uids[i]);
                }
            } else {
                for (uint i = 0; i < uids.length; i++) {
                    var flags = camel_folder.get_message_flags (uids[i]);
                    var currently = (flags & Camel.MessageFlags.FLAGGED) != 0;
                    if (currently == flagged)
                        continue;

                    camel_folder.set_message_flags (
                        uids[i],
                        Camel.MessageFlags.FLAGGED,
                        flagged ? Camel.MessageFlags.FLAGGED : 0
                    );
                    changed.add (uids[i]);
                }
            }
        } finally {
            camel_folder.thaw ();
        }
        if (changed.length == 0)
            return;
        enqueue_flag_flush (account, folder, changed);
    }

    public bool folder_has_pending_flags (Account account, Folder folder) {
        var key = flag_flush_key (account, folder);
        return this.flag_flush_latest.contains (key) || this.transfer_pending.contains (key);
    }

    private static string flag_flush_key (Account account, Folder folder) {
        return "%s\n%s".printf (account.source_uid ?? account.uid, folder.full_name);
    }

    private void enqueue_flag_flush (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        bool expunge = false
    ) {
        var job = new FlagFlushJob () {
            account = account,
            folder = folder,
            uids = uids,
            expunge = expunge,
        };
        /* If a prior job for this folder asked to expunge, keep that. */
        var key = flag_flush_key (account, folder);
        var prior = this.flag_flush_latest.get (key);
        if (prior != null && prior.expunge)
            job.expunge = true;
        this.flag_flush_latest.set (key, job);
        this.flag_flush_queue.add (job);
        /* Local Camel flags are already set. SEEN/FLAGGED/DELETED wait for the
         * sync timer or F5 (flush_pending_local_changes). */
        Utils.sync_log ("flag flush deferred “%s” %u messages%s".printf (
            folder.name,
            uids.length,
            expunge ? " (expunge)" : ""
        ));
        schedule_mutation_registry_save ();
    }

    private async void pump_flag_flush () {
        if (this.flag_flush_running)
            return;

        this.flag_flush_running = true;
        if (this.transfer_flush_running)
            Utils.sync_log ("flag flush while transfer in flight (%u queue)".printf (
                this.flag_flush_queue.length
            ));
        try {
            while (this.flag_flush_queue.length > 0) {
                var job = this.flag_flush_queue[0];
                this.flag_flush_queue.remove_index (0);
                var key = flag_flush_key (job.account, job.folder);
                if (this.flag_flush_latest.get (key) != job)
                    continue;
                yield flush_folder_flags (job);
            }
        } finally {
            this.flag_flush_running = false;
            persist_mutation_registry_now ();
        }
    }

    private async void flush_folder_flags (FlagFlushJob job) {
        var key = flag_flush_key (job.account, job.folder);
        Camel.Folder camel_folder;
        try {
            camel_folder = yield open_camel_folder (job.account, job.folder, null);
        } catch (Error e) {
            warning ("Could not push folder flags: %s", e.message);
            if (this.flag_flush_latest.get (key) == job)
                this.flag_flush_latest.remove (key);
            schedule_mutation_registry_save ();
            return;
        }

        var t0 = Utils.sync_tick ();
        var logged_send_pause = false;
        var logged_user_pause = false;
        var done = 0u;
        while (done < job.uids.length) {
            if (this.flag_flush_latest.get (key) != job)
                return;

            /* Soft SEEN/flag pushes yield to Send like move flush. Expunge stays
             * exclusive (Empty Trash / hard-delete). */
            if (this.send_waiters > 0 && !job.expunge) {
                if (!logged_send_pause) {
                    Utils.sync_log ("flag flush paused “%s” for send (%u/%u)".printf (
                        job.folder.name,
                        done,
                        job.uids.length
                    ));
                    logged_send_pause = true;
                }
                Timeout.add (100, flush_folder_flags.callback);
                yield;
                continue;
            }
            logged_send_pause = false;

            /* Pause before starting sync when draft/open-body already holds or
             * is entering Camel. Mid-flight cancel uses flag_op_cancellable. */
            if (this.high_refresh_waiters > 0 && !this.flush_force && !job.expunge) {
                if (!logged_user_pause) {
                    Utils.sync_log ("flag flush paused “%s” for user (%u/%u)".printf (
                        job.folder.name,
                        done,
                        job.uids.length
                    ));
                    logged_user_pause = true;
                }
                Timeout.add (250, flush_folder_flags.callback);
                yield;
                continue;
            }
            logged_user_pause = false;

            /* Expunge jobs (Empty Trash / hard-delete) take HIGH so account
             * switch / open-body do not starve the purge for minutes. */
            var high = job.expunge;
            try {
                if (job.expunge) {
                    yield push_deleted_and_expunge (
                        camel_folder,
                        job.folder.name,
                        job.uids.length,
                        high,
                        true,
                        null
                    );
                    done = job.uids.length;
                } else {
                    yield enter_camel (false);
                    ulong parent_id = 0;
                    uint timeout_id = 0;
                    /* Generous wall clock for bulk mark-all; Send/draft cancel
                     * mid-flight via flag_op_cancellable. */
                    var timed = bound_cancellable (null, 300, out parent_id, out timeout_id);
                    this.flag_op_cancellable = timed;
                    try {
                        yield camel_folder.synchronize (false, Priority.LOW, timed);
                        done = job.uids.length;
                    } finally {
                        if (this.flag_op_cancellable == timed)
                            this.flag_op_cancellable = null;
                        unbind_cancellable (null, parent_id, timeout_id);
                        leave_camel (false);
                    }
                }
            } catch (Error e) {
                if (Utils.is_cancelled_error (e)) {
                    /* Dirty SEEN flags stay in Camel; keep the job and resume
                     * after Send / draft / open-body releases the lock. */
                    if (this.flag_flush_latest.get (key) == job)
                        this.flag_flush_queue.add (job);
                    Utils.sync_log ("flag flush interrupted “%s” — requeued (%u messages)".printf (
                        job.folder.name,
                        job.uids.length
                    ));
                    schedule_mutation_registry_save ();
                    return;
                }
                warning ("Could not push folder flags for “%s”: %s", job.folder.name, e.message);
                done = job.uids.length;
            }

            Utils.sync_log ("flag flush “%s” %u/%u %s%s".printf (
                job.folder.name,
                done,
                job.uids.length,
                Utils.sync_ms (t0),
                job.expunge ? " (expunge)" : ""
            ));

            Idle.add (flush_folder_flags.callback);
            yield;
        }

        if (this.flag_flush_latest.get (key) != job)
            return;
        apply_camel_counts (job.folder, camel_folder);
        this.flag_flush_latest.remove (key);
        schedule_mutation_registry_save ();
    }

    private void bump_transfer_pending (Account account, Folder folder, int delta) {
        var key = flag_flush_key (account, folder);
        uint n = 0;
        if (this.transfer_pending.contains (key))
            n = this.transfer_pending.get (key);
        if (delta > 0)
            n += (uint) delta;
        else if (n > 0)
            n--;
        if (n == 0)
            this.transfer_pending.remove (key);
        else
            this.transfer_pending.set (key, n);
    }

    private async void pump_transfer_flush () {
        if (this.transfer_flush_running)
            return;

        this.transfer_flush_running = true;
        this.flush_force = true;
        clear_expired_transfer_parks ();
        try {
            while (this.transfer_flush_queue.length > 0) {
                var idx = pick_runnable_transfer_job_index ();
                if (idx < 0) {
                    Utils.sync_log ("move flush wave idle — %u job(s) left".printf (
                        this.transfer_flush_queue.length
                    ));
                    break;
                }
                var job = this.transfer_flush_queue[(uint) idx];
                this.transfer_flush_queue.remove_index ((uint) idx);
                this.transfer_flush_current = job;
                this.transfer_flush_done = 0;
                try {
                    yield flush_folder_transfers (job);
                } finally {
                    this.transfer_flush_current = null;
                    this.transfer_flush_done = 0;
                }
            }
        } finally {
            this.transfer_flush_running = false;
            if (!has_blocking_local_flushes ())
                this.flush_force = false;
            /* Drop mid-flush snapshots (or clear) now that RAM matches reality. */
            persist_mutation_registry_now ();
            /* Flags often enqueue mid-move; keep the pump warm. */
            pump_flag_flush.begin ();
        }
    }

    /* Prefer light moves, then interactive Archive, then archive-subtree bulk. */
    private int pick_runnable_transfer_job_index () {
        int light = -1;
        int heavy_interactive = -1;
        int heavy_bulk = -1;
        for (uint i = 0; i < this.transfer_flush_queue.length; i++) {
            var job = this.transfer_flush_queue[i];
            if (transfer_job_is_parked (job))
                continue;
            if (folder_is_parkable_heavy (job.destination)) {
                if (transfer_job_is_bulk_archive_source (job)) {
                    if (heavy_bulk < 0)
                        heavy_bulk = (int) i;
                } else if (heavy_interactive < 0) {
                    heavy_interactive = (int) i;
                }
            } else if (light < 0) {
                light = (int) i;
            }
        }
        if (light >= 0)
            return light;
        if (heavy_interactive >= 0)
            return heavy_interactive;
        return heavy_bulk;
    }

    /* Archive-subtree reshuffles — lower priority than Inbox→Archive / Trash. */
    private static bool transfer_job_is_bulk_archive_source (TransferFlushJob job) {
        return job.from.is_archive_mailbox;
    }

    private async void flush_folder_transfers (TransferFlushJob job) {
        Camel.Folder source_folder;
        Camel.Folder dest_folder;
        try {
            source_folder = yield open_camel_folder (job.account, job.from, null);
            dest_folder = yield open_camel_folder (job.account, job.destination, null);
        } catch (Error e) {
            warning ("Could not move messages: %s", e.message);
            finish_transfer_job (job, 0, e.message);
            return;
        }

        /* Only drop UIDs already at the destination — never drop because Camel
         * cleared the source summary after a cancelled Graph call. */
        claim_uids_already_at_destination (job, dest_folder, 0);
        if (job.uids.length == 0) {
            Utils.sync_log ("move flush “%s” → “%s” nothing left to move".printf (
                job.from.name,
                job.destination.name
            ));
            bump_transfer_pending (job.account, job.from, -1);
            if (job.from.full_name != job.destination.full_name)
                bump_transfer_pending (job.account, job.destination, -1);
            return;
        }

        if (job.chunk_size == 0)
            job.chunk_size = TRANSFER_CHUNK_START;

        /* Chunked Graph moves. Pause only for send — not for open-body. */
        uint done = 0;
        this.transfer_flush_done = 0;
        var t0 = Utils.sync_tick ();
        var logged_send_pause = false;
        while (done < job.uids.length) {
            if (this.send_waiters > 0) {
                if (!logged_send_pause) {
                    Utils.sync_log ("move flush paused “%s” for send (%u/%u)".printf (
                        job.from.name,
                        done,
                        job.uids.length
                    ));
                    logged_send_pause = true;
                }
                Timeout.add (100, flush_folder_transfers.callback);
                yield;
                continue;
            }
            logged_send_pause = false;

            this.transfer_flush_done = done;
            schedule_mutation_registry_save ();

            /* Skip UIDs already confirmed at destination. */
            while (done < job.uids.length
                && message_at_destination (dest_folder, job.uids[done])) {
                rekey_body (job.account, job.from, job.uids[done], job.destination, job.uids[done]);
                done++;
            }
            if (done >= job.uids.length)
                break;

            var chunk_cap = job.chunk_size;
            if (chunk_cap < TRANSFER_CHUNK_MIN)
                chunk_cap = TRANSFER_CHUNK_MIN;
            var batch = new GenericArray<string> ();
            for (uint i = done; i < job.uids.length && batch.length < chunk_cap; i++) {
                var uid = job.uids[i];
                if (message_at_destination (dest_folder, uid))
                    break;
                /* Camel transfer needs a local summary row. After cancel we
                 * refresh source; if still missing, leave for later refresh. */
                if (source_folder.get_message_info (uid) == null)
                    break;
                batch.add (uid);
            }
            if (batch.length == 0) {
                var uid = job.uids[done];
                /* Prefer the local dest summary first — a full refresh_info on
                 * a large destination can exceed the brief budget and stall
                 * recovery after a cancelled transfer. */
                if (message_at_destination (dest_folder, uid)) {
                    rekey_body (job.account, job.from, uid, job.destination, uid);
                    Utils.sync_log ("move flush claimed at destination “%s” (%u/%u)".printf (
                        job.from.name,
                        done + 1,
                        job.uids.length
                    ));
                    done++;
                    job.stall_rounds = 0;
                    Idle.add (flush_folder_transfers.callback);
                    yield;
                    continue;
                }
                /* Dest summary is often stale after frozen transfers. Probe by
                 * id before waiting on Camel refresh — Graph may already have
                 * finished the move from a prior session. */
                {
                    var hit = yield try_fetch_uid_exists (dest_folder, uid, TRANSFER_DEST_PROBE_SECS);
                    if (hit == true) {
                        rekey_body (job.account, job.from, uid, job.destination, uid);
                        Utils.sync_log ("move flush claimed via fetch “%s” → “%s” (%u/%u)".printf (
                            job.from.name,
                            job.destination.name,
                            done + 1,
                            job.uids.length
                        ));
                        done++;
                        job.stall_rounds = 0;
                        Idle.add (flush_folder_transfers.callback);
                        yield;
                        continue;
                    }
                }
                if (source_folder.get_message_info (uid) == null) {
                    yield refresh_folder_info (source_folder, true, null, REFRESH_INFO_BRIEF);
                    if (message_at_destination (dest_folder, uid)) {
                        rekey_body (job.account, job.from, uid, job.destination, uid);
                        done++;
                        job.stall_rounds = 0;
                        Idle.add (flush_folder_transfers.callback);
                        yield;
                        continue;
                    }
                    if (source_folder.get_message_info (uid) == null) {
                        /* Server rule / other client / prior cancelled Graph move:
                         * UID left the source summary. Locate or drop — never spin. */
                        yield resolve_vanished_transfer_uid (
                            job,
                            done,
                            source_folder,
                            dest_folder,
                            true
                        );
                        if (transfer_job_is_parked (job))
                            return;
                        job.stall_rounds = 0;
                        Idle.add (flush_folder_transfers.callback);
                        yield;
                        continue;
                    }
                }
                continue;
            }

            for (uint i = 0; i < batch.length; i++) {
                if (source_folder.get_message_info (batch[i]) != null)
                    yield capture_local_body (job.account, job.from, batch[i], source_folder);
            }

#if HAVE_CAMEL_3_58
            GenericArray<weak string>? transferred = null;
#else
            GenericArray<string>? transferred = null;
#endif
            try {
                yield enter_camel (true);
                ulong parent_id = 0;
                uint timeout_id = 0;
                var timeout_secs = folder_is_heavy (job.destination)
                    ? TRANSFER_CHUNK_TIMEOUT_HEAVY_SECS
                    : TRANSFER_CHUNK_TIMEOUT_SECS;
                var timed = bound_cancellable (
                    null,
                    timeout_secs,
                    out parent_id,
                    out timeout_id
                );
                this.transfer_op_cancellable = timed;
                freeze_folders_for_transfer (source_folder, dest_folder);
                try {
                    var xfer_t0 = Utils.sync_tick ();
                    yield source_folder.transfer_messages_to (
                        batch,
                        dest_folder,
                        job.delete_original,
                        Priority.DEFAULT,
                        timed,
                        out transferred
                    );
                    Utils.sync_log ("move flush Graph transfer “%s” → “%s” chunk %u %s".printf (
                        job.from.name,
                        job.destination.name,
                        batch.length,
                        Utils.sync_ms (xfer_t0)
                    ));
                } finally {
                    thaw_folders_for_transfer (source_folder, dest_folder);
                    if (this.transfer_op_cancellable == timed)
                        this.transfer_op_cancellable = null;
                    unbind_cancellable (null, parent_id, timeout_id);
                    leave_camel (true);
                }
            } catch (Error e) {
                this.camel_epoch++;
                this.camel_busy = false;

                if (Utils.is_cancelled_error (e)) {
                    if (this.send_waiters > 0) {
                        Utils.sync_log ("move flush interrupted for send (%u/%u)".printf (
                            done,
                            job.uids.length
                        ));
                        Timeout.add (100, flush_folder_transfers.callback);
                        yield;
                        continue;
                    }

                    /* Graph may have committed even though Camel timed out.
                     * Prefer dest id probe over summary — large Archive
                     * summaries stay stale without an expensive refresh_info. */
                    var claimed = claim_batch_arrived (job, batch, done, dest_folder, transferred);
                    if (claimed == 0)
                        claimed = yield claim_batch_arrived_via_fetch (job, batch, done, dest_folder);
                    if (claimed == 0) {
                        yield refresh_folder_info (source_folder, true, null, REFRESH_INFO_BRIEF);
                        claimed = claim_batch_arrived (job, batch, done, dest_folder, transferred);
                        if (claimed == 0)
                            claimed = yield claim_batch_arrived_via_fetch (job, batch, done, dest_folder);
                    }
                    if (claimed > 0) {
                        done += claimed;
                        Utils.sync_log ("move flush after timeout: %u/%u of chunk at destination".printf (
                            claimed,
                            batch.length
                        ));
                        job.stall_rounds = 0;
                        Idle.add (flush_folder_transfers.callback);
                        yield;
                        continue;
                    }

                    /* Restore Camel source summary so the next attempt can see UIDs. */
                    if (source_folder.get_message_info (batch[0]) == null)
                        yield refresh_folder_info (source_folder, true, null, REFRESH_INFO_BRIEF);

                    if (source_folder.get_message_info (batch[0]) == null) {
                        yield resolve_vanished_transfer_uid (
                            job,
                            done,
                            source_folder,
                            dest_folder,
                            false
                        );
                        if (transfer_job_is_parked (job))
                            return;
                        /* resolve dropped, deferred, or claimed — continue wave. */
                        job.stall_rounds = 0;
                        Idle.add (flush_folder_transfers.callback);
                        yield;
                        continue;
                    }

                    job.stall_rounds++;
                    var left = job.uids.length > done ? job.uids.length - done : 0;
                    /* After a hang, shrink to one UID so later UIDs can make
                     * progress instead of re-timing out on the same batch. */
                    if (job.chunk_size > TRANSFER_CHUNK_MIN) {
                        Utils.sync_log ("move flush hang — shrink chunk %u → 1 (%u left)".printf (
                            job.chunk_size,
                            left
                        ));
                        job.chunk_size = TRANSFER_CHUNK_MIN;
                        job.stall_rounds = 0;
                        Timeout.add (500, flush_folder_transfers.callback);
                        yield;
                        continue;
                    }
                    if (source_folder.get_message_info (batch[0]) == null) {
                        /* After cancelled move: locate/claim only — never purge
                         * (Graph may still be settling). */
                        yield resolve_vanished_transfer_uid (
                            job,
                            done,
                            source_folder,
                            dest_folder,
                            false
                        );
                        if (transfer_job_is_parked (job))
                            return;
                        job.stall_rounds = 0;
                        Idle.add (flush_folder_transfers.callback);
                        yield;
                        continue;
                    }
                    if (job.stall_rounds <= 2) {
                        Utils.sync_log ("move flush timeout — retry uid (%u left)".printf (left));
                        Timeout.add (750, flush_folder_transfers.callback);
                        yield;
                        continue;
                    }

                    Utils.sync_log ("move flush stall — defer uid to end (%u left)".printf (left));
                    job.stall_rounds = 0;
                    defer_transfer_range (job, done, 1);
                    Timeout.add (job.uids.length < 2 ? 2000 : 250, flush_folder_transfers.callback);
                    yield;
                    continue;
                }

                if (is_missing_on_server (e)) {
                    /* Check dest summary / id probe first; a full dest refresh_info
                     * can exceed the brief budget on large folders. */
                    var claimed = claim_batch_arrived (job, batch, done, dest_folder, null);
                    if (claimed == 0)
                        claimed = yield claim_batch_arrived_via_fetch (job, batch, done, dest_folder);
                    if (claimed > 0) {
                        done += claimed;
                        Utils.sync_log ("move flush partial missing — arrived %u/%u".printf (
                            claimed,
                            batch.length
                        ));
                        job.stall_rounds = 0;
                        Idle.add (flush_folder_transfers.callback);
                        yield;
                        continue;
                    }

                    var gone_from_source = 0u;
                    for (uint i = 0; i < batch.length; i++) {
                        if (source_folder.get_message_info (batch[i]) == null)
                            gone_from_source++;
                    }

                    /* Gone from source and not at dest yet — locate carefully. */
                    if (gone_from_source > 0
                        && source_folder.get_message_info (batch[0]) == null) {
                        yield resolve_vanished_transfer_uid (
                            job,
                            done,
                            source_folder,
                            dest_folder,
                            true
                        );
                        if (transfer_job_is_parked (job))
                            return;
                        job.stall_rounds = 0;
                        Idle.add (flush_folder_transfers.callback);
                        yield;
                        continue;
                    }

                    /* Still in source: Graph ErrorItemNotFound is often a batch
                     * flake — must not spin. Shrink to 1 and back off. */
                    var left = job.uids.length > done ? job.uids.length - done : 0;
                    job.stall_rounds++;
                    if (job.chunk_size > TRANSFER_CHUNK_MIN) {
                        Utils.sync_log ("move flush missing flake — shrink chunk %u → 1 (%u left): %s".printf (
                            job.chunk_size,
                            left,
                            e.message ?? ""
                        ));
                        job.chunk_size = TRANSFER_CHUNK_MIN;
                        job.stall_rounds = 0;
                        Timeout.add (500, flush_folder_transfers.callback);
                        yield;
                        continue;
                    }
                    if (job.stall_rounds <= 3) {
                        Utils.sync_log ("move flush missing flake — retry uid (%u left): %s".printf (
                            left,
                            e.message ?? ""
                        ));
                        Timeout.add (1000, flush_folder_transfers.callback);
                        yield;
                        continue;
                    }

                    Utils.sync_log ("move flush missing flake — defer uid (%u left): %s".printf (
                        left,
                        e.message ?? ""
                    ));
                    job.stall_rounds = 0;
                    defer_transfer_range (job, done, 1);
                    Timeout.add (1500, flush_folder_transfers.callback);
                    yield;
                    continue;
                }

                warning ("Could not move messages: %s", e.message);
                finish_transfer_job (job, done, e.message);
                return;
            }

            for (uint i = 0; i < batch.length; i++) {
                var uid = batch[i];
                var new_uid = uid;
                if (transferred != null && i < transferred.length
                    && transferred[i] != null && transferred[i].length > 0)
                    new_uid = transferred[i];
                rekey_body (job.account, job.from, uid, job.destination, new_uid);
                var msg_index = done + i;
                if (job.messages != null && msg_index < job.messages.length) {
                    var message = job.messages[msg_index];
                    if (message != null && new_uid != message.uid)
                        message.uid = new_uid;
                }
            }

            job.stall_rounds = 0;
            if (job.chunk_size < TRANSFER_CHUNK_DEFAULT) {
                job.chunk_size = job.chunk_size * 2;
                if (job.chunk_size > TRANSFER_CHUNK_DEFAULT)
                    job.chunk_size = TRANSFER_CHUNK_DEFAULT;
            }
            done += batch.length;
            Utils.sync_log ("move flush “%s” → “%s” %u/%u (chunk %u) %s".printf (
                job.from.name,
                job.destination.name,
                done,
                job.uids.length,
                batch.length,
                Utils.sync_ms (t0)
            ));

            Idle.add (flush_folder_transfers.callback);
            yield;
        }

        apply_camel_counts (job.from, source_folder);
        apply_camel_counts (job.destination, dest_folder);
        bump_transfer_pending (job.account, job.from, -1);
        if (job.from.full_name != job.destination.full_name)
            bump_transfer_pending (job.account, job.destination, -1);
    }

    private static bool message_at_destination (Camel.Folder dest, string uid) {
        return dest.get_message_info (uid) != null;
    }

    /* After a timed-out Graph move, the dest summary is often stale on large
     * folders. get_message(uid) can still confirm the item landed. */
    private async uint claim_batch_arrived_via_fetch (
        TransferFlushJob job,
        GenericArray<string> batch,
        uint done,
        Camel.Folder dest
    ) {
        uint claimed = 0;
        for (uint i = 0; i < batch.length; i++) {
            var uid = batch[i];
            if (message_at_destination (dest, uid)) {
                rekey_body (job.account, job.from, uid, job.destination, uid);
                claimed++;
                continue;
            }
            var hit = yield try_fetch_uid_exists (dest, uid, TRANSFER_DEST_PROBE_SECS);
            if (hit != true)
                break;
            rekey_body (job.account, job.from, uid, job.destination, uid);
            var msg_index = done + i;
            if (job.messages != null && msg_index < job.messages.length) {
                var message = job.messages[msg_index];
                if (message != null)
                    message.uid = uid;
            }
            Utils.sync_log ("move flush claimed via dest fetch “%s”".printf (job.destination.name));
            claimed++;
        }
        return claimed;
    }

    /* UID vanished from the source Camel summary (server rule, other client,
     * or a cancelled Graph move that already committed). Locate it in likely
     * folders. Only purge local data when @allow_purge and every probe
     * confirms absence — a single-folder ErrorItemNotFound is not enough. */
    private async void resolve_vanished_transfer_uid (
        TransferFlushJob job,
        uint index,
        Camel.Folder source_folder,
        Camel.Folder dest_folder,
        bool allow_purge
    ) {
        if (index >= job.uids.length)
            return;
        var uid = job.uids[index];
        var left = job.uids.length > index ? job.uids.length - index : 0;
        var remaining_after = left > 0 ? left - 1 : 0;

        if (message_at_destination (dest_folder, uid)) {
            rekey_body (job.account, job.from, uid, job.destination, uid);
            remove_transfer_uid_at (job, index);
            Utils.sync_log ("move flush locate: already at “%s” (%u left)".printf (
                job.destination.name,
                remaining_after
            ));
            return;
        }

        /* Dest id probe first — the usual landing place after a hung move. */
        var dest_hit = yield try_fetch_uid_exists (dest_folder, uid, TRANSFER_DEST_PROBE_SECS);
        if (dest_hit == true) {
            rekey_body (job.account, job.from, uid, job.destination, uid);
            remove_transfer_uid_at (job, index);
            Utils.sync_log ("move flush locate: fetched at “%s” (%u left)".printf (
                job.destination.name,
                remaining_after
            ));
            return;
        }

        bool confirmed_absent;
        bool reachable_unindexed;
        var found = yield seek_vanished_uid (
            job.account,
            job.from,
            job.destination,
            uid,
            source_folder,
            dest_folder,
            out confirmed_absent,
            out reachable_unindexed
        );
        if (found != null) {
            rekey_body (job.account, job.from, uid, found, uid);
            remove_transfer_uid_at (job, index);
            Utils.sync_log ("move flush locate: “%s” now in “%s” — drop from queue (%u left)".printf (
                job.from.name,
                found.name,
                remaining_after
            ));
            return;
        }

        if (confirmed_absent && allow_purge) {
            yield forget_vanished_transfer_uid (job.account, job.from, source_folder, uid);
            remove_transfer_uid_at (job, index);
            Utils.sync_log ("move flush locate: confirmed absent in all probed folders — drop (%u left)".printf (
                remaining_after
            ));
            return;
        }

        /* Not safe to purge: keep body. Defer this UID and keep draining the
         * rest of the job in the same wave (do not park the whole remainder). */
        if (folder_is_parkable_heavy (job.destination) && !allow_purge) {
            Utils.sync_log ("move flush locate: defer uid after cancel (%u left) — %s".printf (
                remaining_after,
                confirmed_absent
                    ? "absent after cancel"
                    : (reachable_unindexed ? "reachable unindexed" : "unconfirmed after cancel")
            ));
            defer_transfer_range (job, index, 1);
            return;
        }

        remove_transfer_uid_at (job, index);
        if (confirmed_absent && !allow_purge) {
            Utils.sync_log ("move flush locate: absent after cancel — keep local body (%u left)".printf (
                remaining_after
            ));
        } else if (reachable_unindexed) {
            Utils.sync_log ("move flush locate: still reachable by id, folder unknown — keep local body (%u left)".printf (
                remaining_after
            ));
        } else {
            Utils.sync_log ("move flush locate: unconfirmed — keep local body, skip move (%u left)".printf (
                remaining_after
            ));
        }
    }

    private void remove_transfer_uid_at (TransferFlushJob job, uint index) {
        if (index >= job.uids.length)
            return;
        var uids = new GenericArray<string> ();
        GenericArray<Message>? messages = null;
        if (job.messages != null)
            messages = new GenericArray<Message> ();
        for (uint i = 0; i < job.uids.length; i++) {
            if (i == index)
                continue;
            uids.add (job.uids[i]);
            if (messages != null && job.messages != null && i < job.messages.length)
                messages.add (job.messages[i]);
        }
        job.uids = uids;
        job.messages = messages;
        schedule_mutation_registry_save ();
    }

    private async void forget_vanished_transfer_uid (
        Account account,
        Folder from,
        Camel.Folder source_folder,
        string uid
    ) {
        var key = body_key (account, from, uid);
        this.body_cache.remove (key);
        yield drop_disk_body (source_folder, uid, null);
    }

    /* Walk likely folders once. Returns the folder when found; otherwise sets
     * confirmed_absent only if every get_message probe returned NOT_FOUND. */
    private async Folder? seek_vanished_uid (
        Account account,
        Folder from,
        Folder destination,
        string uid,
        Camel.Folder source_folder,
        Camel.Folder dest_folder,
        out bool confirmed_absent,
        out bool reachable_unindexed
    ) {
        confirmed_absent = false;
        reachable_unindexed = false;

        var candidates = yield transfer_locate_candidates (account, from, destination);
        var dest_full = dest_folder.get_full_name () ?? destination.full_name;

        /* Pass 1: local Camel summaries only (fast). */
        for (uint i = 0; i < candidates.length; i++) {
            var folder = candidates[i];
            try {
                var camel = folder.full_name == destination.full_name
                    ? dest_folder
                    : yield open_camel_folder (account, folder, null);
                if (camel.get_message_info (uid) != null)
                    return folder;
            } catch (Error e) {
                debug ("locate open “%s”: %s", folder.name, e.message);
            }
        }

        /* Pass 2: brief refresh on small likely targets (not Archive). */
        for (uint i = 0; i < candidates.length; i++) {
            var folder = candidates[i];
            if (folder_is_heavy (folder))
                continue;
            try {
                var camel = folder.full_name == destination.full_name
                    ? dest_folder
                    : yield open_camel_folder (account, folder, null);
                yield refresh_folder_info (camel, true, null, REFRESH_INFO_BRIEF);
                if (camel.get_message_info (uid) != null)
                    return folder;
            } catch (Error e) {
                debug ("locate refresh “%s”: %s", folder.name, e.message);
            }
        }

        /* Pass 3: folder-scoped get_message by id on source + every candidate.
         * NOT_FOUND in one folder is not global deletion on Graph. */
        bool any_unknown = false;
        bool any_hit = false;
        uint missing_probes = 0;
        uint total_probes = 0;

        var source_hit = yield try_fetch_uid_exists (source_folder, uid);
        total_probes++;
        if (source_hit == true) {
            any_hit = true;
            reachable_unindexed = true;
        } else if (source_hit == false) {
            missing_probes++;
        } else {
            any_unknown = true;
        }

        for (uint i = 0; i < candidates.length; i++) {
            var folder = candidates[i];
            if (folder.full_name == from.full_name)
                continue;

            Camel.Folder camel;
            if (folder.full_name == destination.full_name || folder.full_name == dest_full) {
                camel = dest_folder;
            } else {
                try {
                    camel = yield open_camel_folder (account, folder, null);
                } catch (Error e) {
                    debug ("locate fetch-open “%s”: %s", folder.name, e.message);
                    any_unknown = true;
                    continue;
                }
            }

            var probe_secs = (folder.full_name == destination.full_name
                || folder_is_heavy (folder))
                ? TRANSFER_DEST_PROBE_SECS
                : 8;
            var hit = yield try_fetch_uid_exists (camel, uid, probe_secs);
            total_probes++;
            if (hit == true)
                return folder;
            if (hit == false)
                missing_probes++;
            else
                any_unknown = true;
        }

        if (any_hit && !any_unknown) {
            /* Source get_message worked but no folder claimed it — keep body. */
            reachable_unindexed = true;
            return null;
        }

        confirmed_absent = !any_unknown && !any_hit
            && total_probes > 0
            && missing_probes == total_probes;
        return null;
    }

    private async bool? try_fetch_uid_exists (
        Camel.Folder camel_folder,
        string uid,
        uint timeout_secs = 8
    ) {
        ulong parent_id = 0;
        uint timeout_id = 0;
        var timed = bound_cancellable (null, timeout_secs > 0 ? timeout_secs : 8, out parent_id, out timeout_id);
        try {
            yield enter_camel (true);
            try {
                var mime = yield camel_folder.get_message (uid, Priority.DEFAULT, timed);
                return mime != null;
            } finally {
                leave_camel (true);
            }
        } catch (Error e) {
            if (is_missing_on_server (e) || error_text_means_missing (e.message))
                return false;
            if (Utils.is_cancelled_error (e))
                return null;
            Utils.sync_log ("locate probe get_message “%s”: %s".printf (
                camel_folder.get_full_display_name () ?? camel_folder.get_full_name () ?? "?",
                e.message
            ));
            return null;
        } finally {
            unbind_cancellable (null, parent_id, timeout_id);
        }
    }

    private async GenericArray<Folder> transfer_locate_candidates (
        Account account,
        Folder from,
        Folder destination
    ) {
        var out = new GenericArray<Folder> ();
        var seen = new HashTable<string, uint8> (str_hash, str_equal);

        if (destination.full_name != from.full_name) {
            seen.set (destination.full_name, 1);
            out.add (destination);
        }

        GenericArray<Folder> folders;
        try {
            folders = yield list_folders (account, null, false);
        } catch (Error e) {
            debug ("locate folder list: %s", e.message);
            return out;
        }

        Folder? trash = null;
        Folder? junk = null;
        Folder? archive = null;
        Folder? inbox = null;
        Folder? sent = null;
        for (uint i = 0; i < folders.length; i++) {
            switch (folders[i].kind) {
                case FolderKind.TRASH:
                    if (trash == null)
                        trash = folders[i];
                    break;
                case FolderKind.JUNK:
                    if (junk == null)
                        junk = folders[i];
                    break;
                case FolderKind.ARCHIVE:
                case FolderKind.ALL:
                    if (archive == null)
                        archive = folders[i];
                    break;
                case FolderKind.INBOX:
                    if (inbox == null)
                        inbox = folders[i];
                    break;
                case FolderKind.SENT:
                    if (sent == null)
                        sent = folders[i];
                    break;
                default:
                    break;
            }
        }

        Folder?[] priority = { trash, junk, archive, inbox, sent };
        for (uint i = 0; i < priority.length; i++) {
            var folder = priority[i];
            if (folder == null || folder.full_name == from.full_name)
                continue;
            if (seen.contains (folder.full_name))
                continue;
            seen.set (folder.full_name, 1);
            out.add (folder);
        }

        /* Siblings under the same parent (e.g. other Inbox children). */
        var slash = from.full_name.last_index_of_char ('/');
        var parent = slash > 0 ? from.full_name.substring (0, slash) : "";
        for (uint i = 0; i < folders.length && out.length < 16; i++) {
            var folder = folders[i];
            if (parent.length == 0)
                continue;
            if (folder.full_name == from.full_name)
                continue;
            if (!folder.full_name.has_prefix (parent + "/"))
                continue;
            if (folder.full_name.contains ("/")
                && folder.full_name.substring (parent.length + 1).contains ("/"))
                continue;
            if (seen.contains (folder.full_name))
                continue;
            seen.set (folder.full_name, 1);
            out.add (folder);
        }
        return out;
    }

    /* Drop leading UIDs that already live in dest (same Graph id across folders). */
    private void claim_uids_already_at_destination (
        TransferFlushJob job,
        Camel.Folder dest,
        uint from_index
    ) {
        if (from_index >= job.uids.length)
            return;

        var kept_uids = new GenericArray<string> ();
        GenericArray<Message>? kept_messages = null;
        if (job.messages != null)
            kept_messages = new GenericArray<Message> ();

        for (uint i = 0; i < from_index; i++) {
            kept_uids.add (job.uids[i]);
            if (kept_messages != null && job.messages != null && i < job.messages.length)
                kept_messages.add (job.messages[i]);
        }
        for (uint i = from_index; i < job.uids.length; i++) {
            var uid = job.uids[i];
            if (message_at_destination (dest, uid)) {
                rekey_body (job.account, job.from, uid, job.destination, uid);
                continue;
            }
            kept_uids.add (uid);
            if (kept_messages != null && job.messages != null && i < job.messages.length)
                kept_messages.add (job.messages[i]);
        }
        job.uids = kept_uids;
        job.messages = kept_messages;
    }

    /* How many leading UIDs of this batch are already at dest (prefix only). */
    private uint claim_batch_arrived (
        TransferFlushJob job,
        GenericArray<string> batch,
        uint done,
        Camel.Folder dest,
#if HAVE_CAMEL_3_58
        GenericArray<weak string>? transferred
#else
        GenericArray<string>? transferred
#endif
    ) {
        uint claimed = 0;
        for (uint i = 0; i < batch.length; i++) {
            var uid = batch[i];
            var new_uid = uid;
            if (transferred != null && i < transferred.length
                && transferred[i] != null && transferred[i].length > 0)
                new_uid = transferred[i];
            if (!message_at_destination (dest, uid) && !message_at_destination (dest, new_uid))
                break;
            rekey_body (job.account, job.from, uid, job.destination, new_uid);
            var msg_index = done + i;
            if (job.messages != null && msg_index < job.messages.length) {
                var message = job.messages[msg_index];
                if (message != null && new_uid != message.uid)
                    message.uid = new_uid;
            }
            claimed++;
        }
        return claimed;
    }

    /* After repeated Graph timeouts, try other UIDs first instead of dropping. */
    private static void defer_transfer_range (TransferFlushJob job, uint index, uint count) {
        if (count == 0 || index >= job.uids.length)
            return;
        if (count > job.uids.length - index)
            count = job.uids.length - index;
        if (job.uids.length < 2 || count >= job.uids.length)
            return;

        var deferred_uids = new GenericArray<string> ();
        GenericArray<Message>? deferred_messages = null;
        if (job.messages != null)
            deferred_messages = new GenericArray<Message> ();

        for (uint i = 0; i < count; i++) {
            deferred_uids.add (job.uids[index + i]);
            if (deferred_messages != null && job.messages != null && index + i < job.messages.length)
                deferred_messages.add (job.messages[index + i]);
        }

        var uids = new GenericArray<string> ();
        GenericArray<Message>? messages = null;
        if (job.messages != null)
            messages = new GenericArray<Message> ();

        for (uint i = 0; i < job.uids.length; i++) {
            if (i >= index && i < index + count)
                continue;
            uids.add (job.uids[i]);
            if (messages != null && job.messages != null && i < job.messages.length)
                messages.add (job.messages[i]);
        }
        for (uint i = 0; i < deferred_uids.length; i++) {
            uids.add (deferred_uids[i]);
            if (messages != null && deferred_messages != null)
                messages.add (deferred_messages[i]);
        }

        job.uids = uids;
        job.messages = messages;
    }

    private void finish_transfer_job (TransferFlushJob job, uint done, string error) {
        bump_transfer_pending (job.account, job.from, -1);
        if (job.from.full_name != job.destination.full_name)
            bump_transfer_pending (job.account, job.destination, -1);

        var remaining = new GenericArray<string> ();
        for (uint i = done; i < job.uids.length; i++)
            remaining.add (job.uids[i]);
        if (remaining.length == 0) {
            schedule_mutation_registry_save ();
            return;
        }
        /* Never surface cancel/timeout as a user-visible transfer failure —
         * that un-hides archived mail and shows “operation cancelled”. */
        var down = error.down ();
        if (down.contains ("cancel") || down.contains ("annullat") || down.contains ("abgebrochen")) {
            Utils.sync_log ("move flush soft-fail (cancel) — requeue %u".printf (remaining.length));
            this.transfer_flush_queue.add (new TransferFlushJob () {
                account = job.account,
                from = job.from,
                destination = job.destination,
                uids = remaining,
                messages = null,
                delete_original = job.delete_original,
                chunk_size = job.chunk_size > 0 ? job.chunk_size : TRANSFER_CHUNK_START,
            });
            bump_transfer_pending (job.account, job.from, 1);
            if (job.from.full_name != job.destination.full_name)
                bump_transfer_pending (job.account, job.destination, 1);
            schedule_mutation_registry_save ();
            Timeout.add_seconds (3, () => {
                pump_transfer_flush.begin ();
                return Source.REMOVE;
            });
            return;
        }
        /* Item already gone on Graph — keep hides, do not toast. */
        if (error_text_means_missing (error)) {
            Utils.sync_log ("move flush soft-fail (missing) — drop %u without unhide".printf (remaining.length));
            schedule_mutation_registry_save ();
            return;
        }
        this.transfer_failed (job.account, job.from, remaining, error);
        schedule_mutation_registry_save ();
    }

    public async void create_mailbox_folder (Account account, Folder parent, string name) throws Error {
        var cleaned = name.strip ();
        if (cleaned.length == 0)
            throw new IOError.INVALID_ARGUMENT (_("Enter a folder name."));
        if (cleaned.contains ("/") || cleaned.contains ("\\")) {
            throw new IOError.INVALID_ARGUMENT (
                _("Folder names cannot contain slashes.")
            );
        }

        var store = yield open_store (account, null);
        yield enter_camel (true);
        try {
            yield store.create_folder (parent.full_name, cleaned, Priority.DEFAULT, null);
        } finally {
            leave_camel (true);
        }
    }

    public async void rename_mailbox_folder (Account account, Folder folder, string new_full_name) throws Error {
        if (folder.full_name == new_full_name)
            return;

        var store = yield open_store (account, null);
        yield enter_camel (true);
        try {
            yield store.rename_folder (folder.full_name, new_full_name, Priority.DEFAULT, null);
        } finally {
            leave_camel (true);
        }
    }

    public async void delete_mailbox_folder (Account account, Folder folder) throws Error {
        var store = yield open_store (account, null);
        yield enter_camel (true);
        try {
            yield store.delete_folder (folder.full_name, Priority.DEFAULT, null);
        } finally {
            leave_camel (true);
        }
    }

    public static string unique_child_path (string? parent_full, string leaf, GenericArray<Folder> folders) {
        var dest = parent_full != null && parent_full.length > 0
            ? "%s/%s".printf (parent_full, leaf)
            : leaf;
        if (!contains_full_name (folders, dest))
            return dest;

        for (int n = 2; n < 100; n++) {
            var candidate = parent_full != null && parent_full.length > 0
                ? "%s/%s-%d".printf (parent_full, leaf, n)
                : "%s-%d".printf (leaf, n);
            if (!contains_full_name (folders, candidate))
                return candidate;
        }
        return dest;
    }

    private static bool contains_full_name (GenericArray<Folder> folders, string full_name) {
        for (uint i = 0; i < folders.length; i++) {
            if (folders[i].full_name == full_name)
                return true;
        }
        return false;
    }

    private static Camel.MimeMessage? message_from_local_cache (Camel.Folder camel_folder, string uid) {
        return camel_folder.get_message_cached (uid, null);
    }

    private async void capture_local_body (Account account, Folder folder, string uid, Camel.Folder camel_folder) {
        if (this.body_cache.contains (body_key (account, folder, uid)))
            return;

        var mime = message_from_local_cache (camel_folder, uid);
        if (mime != null)
            this.body_cache.set (body_key (account, folder, uid), MessageContent.from_mime (uid, mime));
    }

    private static bool is_missing_on_server (Error error) {
        return error is IOError.NOT_FOUND
            || error_text_means_missing (error.message);
    }

    public static bool error_text_means_missing (string? text) {
        if (text == null || text.length == 0)
            return false;
        var down = text.down ();
        return down.contains ("erroritemnotfound")
            || down.contains ("not found in the store")
            || down.contains ("specified object was not found")
            || down.contains ("failed to get the correct properties");
    }

    private async Camel.Folder open_camel_folder (Account account, Folder folder, Cancellable? cancellable) throws Error {
        if (folder.is_virtual_view) {
            throw new IOError.NOT_SUPPORTED (
                _("“%s” is a local view, not a mail folder.").printf (folder.name)
            );
        }

        var store = yield open_store (account, cancellable);
        var camel_folder = yield store.get_folder (
            folder.full_name,
            Camel.StoreGetFolderFlags.NONE,
            Priority.DEFAULT,
            cancellable
        );
        if (camel_folder == null) {
            throw new IOError.NOT_FOUND (
                _("Folder “%s” was not found.").printf (folder.name)
            );
        }

        return camel_folder;
    }

    private static string body_key (Account account, Folder folder, string uid) {
        return "%s\n%s\n%s".printf (account.source_uid ?? account.uid, folder.full_name, uid);
    }

    private void drop_body (Account account, Folder folder, string uid) {
        this.body_cache.remove (body_key (account, folder, uid));
    }

    public static string mail_data_root () {
        return Path.build_filename (Environment.get_user_data_dir (), "letter", "mail");
    }

    public static string mail_cache_root () {
        return Path.build_filename (Environment.get_user_cache_dir (), "letter", "mail");
    }

    public static uint64 account_storage_bytes (Account account) {
        var uid = account.source_uid;
        if (uid == null || uid.length == 0)
            return 0;

        return directory_size (Path.build_filename (mail_cache_root (), uid))
            + directory_size (Path.build_filename (mail_data_root (), uid));
    }

    public static uint64 total_storage_bytes (AccountStore store) {
        uint64 total = 0;
        for (uint i = 0; i < store.items.get_n_items (); i++) {
            var account = store.items.get_item (i) as Account;
            if (account == null || account.kind == AccountKind.LOCAL)
                continue;
            total += account_storage_bytes (account);
        }
        return total;
    }

    public async void reset_account_storage (Account account) throws Error {
        var uid = account.source_uid;
        if (uid == null || uid.length == 0) {
            throw new IOError.NOT_SUPPORTED (
                _("This account has no local mail library.")
            );
        }

        unwatch_account_folders (uid);

        var service = ref_service (uid);
        if (service != null) {
            try {
                var offline = service as Camel.OfflineStore;
                if (offline != null && offline.get_online ())
                    yield offline.set_online (false, Priority.DEFAULT, null);
                else if (service.get_connection_status () == Camel.ServiceConnectionStatus.CONNECTED)
                    yield service.disconnect (true, Priority.DEFAULT, null);
            } catch (Error e) {
                debug ("Could not disconnect %s before reset: %s", uid, e.message);
            }
            remove_service (service);
        }

        drop_account_bodies (account);
        reset_prefetch_progress (account);
        delete_folder_tree_cache (uid);
        delete_header_list_cache (uid);
        delete_account_tree (Path.build_filename (mail_cache_root (), uid));
        delete_account_tree (Path.build_filename (mail_data_root (), uid));
    }

    public static string folder_tree_cache_dir () {
        return Path.build_filename (Environment.get_user_cache_dir (), "letter", "folder-trees");
    }

    public static string folder_tree_cache_file (string account_uid) {
        var safe = Checksum.compute_for_string (ChecksumType.SHA256, account_uid);
        return Path.build_filename (folder_tree_cache_dir (), safe);
    }

    public static void delete_folder_tree_cache (string account_uid) {
        try {
            File.new_for_path (folder_tree_cache_file (account_uid)).delete ();
        } catch (Error e) {
            if (!(e is IOError.NOT_FOUND))
                debug ("Could not delete folder tree cache: %s", e.message);
        }
    }

    /* Persisted Letter header lists so Archive/Sent reopen without walking
     * Camel's full UID set (collect_messages) on every cold start. */
    public static string header_list_cache_dir () {
        return Path.build_filename (Environment.get_user_cache_dir (), "letter", "header-lists");
    }

    public static string header_list_cache_file (string account_uid, string folder_full_name) {
        var account_safe = Checksum.compute_for_string (ChecksumType.SHA256, account_uid);
        var folder_safe = Checksum.compute_for_string (ChecksumType.SHA256, folder_full_name);
        return Path.build_filename (header_list_cache_dir (), account_safe, folder_safe);
    }

    public static void delete_header_list_cache (string account_uid) {
        var account_safe = Checksum.compute_for_string (ChecksumType.SHA256, account_uid);
        var root = header_list_cache_dir ();
        var dir_path = Path.build_filename (root, account_safe);
        if (!dir_path.has_prefix (root + Path.DIR_SEPARATOR_S) && dir_path != root)
            return;
        try {
            var file = File.new_for_path (dir_path);
            if (file.query_exists ())
                delete_file_recursive (file);
        } catch (Error e) {
            debug ("Could not delete header list cache: %s", e.message);
        }
    }

    private void drop_account_bodies (Account account) {
        var prefix = "%s\n".printf (account.source_uid ?? account.uid);
        var keys = new GenericArray<string> ();
        this.body_cache.foreach ((key, content) => {
            if (key.has_prefix (prefix))
                keys.add (key);
        });
        for (uint i = 0; i < keys.length; i++)
            this.body_cache.remove (keys[i]);
    }

    private static uint64 directory_size (string path) {
        var file = File.new_for_path (path);
        if (!file.query_exists ())
            return 0;
        return directory_size_file (file);
    }

    private static uint64 directory_size_file (File dir) {
        uint64 total = 0;
        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS
            );
            FileInfo? info = null;
            while ((info = enumerator.next_file ()) != null) {
                if (info.get_file_type () == FileType.DIRECTORY)
                    total += directory_size_file (enumerator.get_child (info));
                else
                    total += info.get_size ();
            }
        } catch (Error e) {
            debug ("Could not measure %s: %s", dir.get_path (), e.message);
        }
        return total;
    }

    private void delete_account_tree (string path) throws Error {
        var cache_root = mail_cache_root ();
        var data_root = mail_data_root ();
        if (path != cache_root && path != data_root
            && !path.has_prefix (cache_root + Path.DIR_SEPARATOR_S)
            && !path.has_prefix (data_root + Path.DIR_SEPARATOR_S)) {
            throw new IOError.NOT_SUPPORTED (
                _("Refusing to delete files outside Letter’s library.")
            );
        }

        var file = File.new_for_path (path);
        if (!file.query_exists ())
            return;
        delete_file_recursive (file);
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

    public Identity? get_identity (Account account) {
        if (account.source_uid == null)
            return null;

        var source = this.registry.ref_source (account.source_uid);
        if (source == null)
            return null;

        var mail_account = (E.SourceMailAccount) source.get_extension (E.SOURCE_EXTENSION_MAIL_ACCOUNT);
        var identity_uid = mail_account.get_identity_uid ();
        E.Source? identity_source = identity_uid != null ? this.registry.ref_source (identity_uid) : source;
        if (identity_source == null || !identity_source.has_extension (E.SOURCE_EXTENSION_MAIL_IDENTITY))
            identity_source = source.has_extension (E.SOURCE_EXTENSION_MAIL_IDENTITY) ? source : null;
        if (identity_source == null)
            return null;

        var identity = (E.SourceMailIdentity) identity_source.get_extension (E.SOURCE_EXTENSION_MAIL_IDENTITY);
        var address = identity.get_address ();
        if (address == null || address.length == 0)
            address = account.email;
        if (address == null || address.length == 0)
            return null;

        string[] aliases = {};
        var table = identity.get_aliases_as_hash_table ();
        if (table != null) {
            table.foreach ((key, name) => {
                var alias = (key ?? "").strip ().down ();
                if (alias.contains ("@") && alias != address.down ())
                    aliases += alias;
            });
        }

        return new Identity () {
            name = identity.get_name () ?? account.display_name,
            address = address,
            aliases = aliases,
        };
    }

    public void ensure_can_send (Account account, string to, string? cc, string? bcc) throws Error {
        if (get_identity (account) == null)
            throw new IOError.FAILED (_("This account has no sending identity."));

        var to_addr = parse_addresses (to);
        if (to_addr.length () == 0)
            throw new IOError.INVALID_ARGUMENT (_("Add at least one recipient."));

        ensure_valid_recipients (to_addr);
        ensure_valid_recipients (parse_addresses (cc));
        ensure_valid_recipients (parse_addresses (bcc));
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
        if (identity == null)
            throw new IOError.FAILED (_("This account has no sending identity."));
        var to_addr = parse_addresses (to);
        var cc_addr = parse_addresses (cc);
        var bcc_addr = parse_addresses (bcc);

        var from_addr = new Camel.InternetAddress ();
        from_addr.add (identity.name, identity.address);

        var recipients = new Camel.InternetAddress ();
        recipients.cat (to_addr);
        if (cc_addr.length () > 0)
            recipients.cat (cc_addr);
        if (bcc_addr.length () > 0)
            recipients.cat (bcc_addr);

        var mime = build_outgoing_mime (
            identity,
            to_addr,
            cc_addr,
            bcc_addr,
            subject,
            body,
            html,
            attachments,
            reply_of,
            is_forward,
            high_priority
        );

        var transport = yield open_transport (account, cancellable);
        bool saved = false;
        var t0 = Utils.sync_tick ();
        Utils.sync_log ("send start from=%s to=%s".printf (identity.address, to));
        Utils.sync_log ("send mime recipients to=%s cc=%s bcc=%s".printf (
            to_addr.encode () ?? "",
            cc_addr.length () > 0 ? (cc_addr.encode () ?? "") : "",
            bcc_addr.length () > 0 ? (bcc_addr.encode () ?? "") : ""
        ));
        send_starting ();
        this.send_waiters++;
        try {
            yield enter_camel (true);
            ulong parent_id = 0;
            uint timeout_id = 0;
            var timed = bound_cancellable (cancellable, 90, out parent_id, out timeout_id);
            try {
                yield transport.send_to (mime, from_addr, recipients, Priority.DEFAULT, timed, out saved);
            } finally {
                unbind_cancellable (cancellable, parent_id, timeout_id);
                leave_camel (true);
            }
        } finally {
            this.send_waiters--;
            send_finished ();
        }
        Utils.sync_log ("send_to done %s saved_on_server=%s".printf (Utils.sync_ms (t0), saved.to_string ()));

        Message? sent = null;
        Folder? sent_folder = null;
        string? uid = null;
        if (!saved && !backend_saves_sent_on_server (account)) {
            try {
                uid = yield save_to_folder (account, FolderKind.SENT, mime, cancellable, out sent_folder);
            } catch (Error save_error) {
                warning ("Could not copy the sent message: %s", save_error.message);
            }
        } else if (!saved) {
            Utils.sync_log ("skip Sent append; %s already saves a server copy".printf (
                account.backend_name ?? account.kind.label ()
            ));
        }
        if (sent_folder == null)
            sent_folder = yield find_special_folder (account, FolderKind.SENT, cancellable);
        if (sent_folder != null) {
            var id = uid != null && uid.length > 0
                ? uid
                : "local-sent-%lld".printf (new DateTime.now_utc ().to_unix ());
            var content = MessageContent.from_mime (id, mime);
            this.body_cache.set (body_key (account, sent_folder, id), content);
            sent = message_from_mime (id, mime, sent_folder, content.plain_text ?? body);
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
        out Folder? drafts_folder = null
    ) throws Error {
        drafts_folder = null;
        var identity = get_identity (account);
        if (identity == null) {
            throw new IOError.FAILED (_("This account has no sending identity."));
        }

        var to_addr = parse_addresses (to);
        var cc_addr = parse_addresses (cc);
        var bcc_addr = parse_addresses (bcc);
        var mime = build_outgoing_mime (
            identity,
            to_addr,
            cc_addr,
            bcc_addr,
            subject,
            body,
            html,
            attachments,
            reply_of,
            is_forward,
            high_priority
        );
        Folder? drafts;
        var uid = yield save_to_folder (account, FolderKind.DRAFTS, mime, cancellable, out drafts);
        if (drafts == null)
            return null;

        drafts_folder = drafts;
        if (uid == null || uid.length == 0)
            uid = "local-draft-%lld".printf (new DateTime.now_utc ().to_unix ());
        var content = MessageContent.from_mime (uid, mime);
        this.body_cache.set (body_key (account, drafts, uid), content);
        var draft = message_from_mime (uid, mime, drafts, content.plain_text ?? body);

        /* Replace previous revision: purge locally and push to the server now.
         * Deferred flag flush left duplicate Drafts on Microsoft 365. */
        if (replace_uid != null && replace_uid.length > 0 && replace_uid != uid) {
            var old_folder = replace_folder ?? drafts;
            try {
                yield purge_replaced_draft (account, old_folder, replace_uid, cancellable);
            } catch (Error e) {
                warning ("Could not replace previous draft: %s", e.message);
            }
        }

        draft_saved (account, draft, replace_uid);
        return draft;
    }

    /* Drop a superseded Drafts UID from Camel and the server immediately. */
    private async void purge_replaced_draft (
        Account account,
        Folder folder,
        string uid,
        Cancellable? cancellable
    ) throws Error {
        var camel_folder = yield open_camel_folder (account, folder, cancellable);
        camel_folder.set_message_flags (uid, Camel.MessageFlags.DELETED, Camel.MessageFlags.DELETED);
        drop_body (account, folder, uid);
        apply_camel_counts (folder, camel_folder);
        if (folder.kind == FolderKind.DRAFTS)
            draft_removed (account, folder, uid);

        try {
            /* Graph: synchronize pushes DELETED; full-folder expunge is unsafe.
             * Other backends can expunge the single deleted UID. */
            yield push_deleted_and_expunge (
                camel_folder,
                folder.name,
                1,
                true,
                !backend_saves_sent_on_server (account),
                cancellable
            );
        } catch (Error e) {
            warning ("Immediate draft purge deferred to flag flush: %s", e.message);
            var uids = new GenericArray<string> ();
            uids.add (uid);
            enqueue_flag_flush (account, folder, uids);
        }
    }

    private static Camel.MimeMessage build_outgoing_mime (
        Identity identity,
        Camel.InternetAddress to_addr,
        Camel.InternetAddress cc_addr,
        Camel.InternetAddress bcc_addr,
        string subject,
        string body,
        string? html,
        GenericArray<Attachment>? attachments,
        MessageContent? reply_of = null,
        bool is_forward = false,
        bool high_priority = false
    ) {
        var from_addr = new Camel.InternetAddress ();
        from_addr.add (identity.name, identity.address);

        var mime = new Camel.MimeMessage ();
        mime.set_from (from_addr);
        if (to_addr.length () > 0)
            mime.set_recipients (Camel.RECIPIENT_TYPE_TO, to_addr);
        if (cc_addr.length () > 0)
            mime.set_recipients (Camel.RECIPIENT_TYPE_CC, cc_addr);
        if (bcc_addr.length () > 0)
            mime.set_recipients (Camel.RECIPIENT_TYPE_BCC, bcc_addr);
        mime.set_subject (subject.strip ().length > 0 ? subject.strip () : _("(No subject)"));
        mime.set_date ((time_t) new DateTime.now_local ().to_unix (), 0);
        apply_outgoing_thread_headers (mime, identity, reply_of, is_forward);
        MessageContent.apply_priority_headers (mime, high_priority);

        var plain = body ?? "";
        var has_html = html != null && html.strip ().length > 0;
        var has_files = attachments != null && attachments.length > 0;
        if (!has_html && !has_files)
            mime.set_content (plain.data, "text/plain; charset=UTF-8");
        else
            ((Camel.Medium) mime).set_content (build_outgoing_body (plain, html, attachments));

        mime.set_best_encoding (Camel.BestencRequired.GET_ENCODING, Camel.BestencEncoding.@8BIT);
        return mime;
    }

    private static void apply_outgoing_thread_headers (
        Camel.MimeMessage mime,
        Identity identity,
        MessageContent? reply_of,
        bool is_forward = false
    ) {
        mime.set_message_id (Camel.header_msgid_generate (message_id_domain (identity.address)));
        if (reply_of == null)
            return;

        var parent_id = angle_message_id (reply_of.message_id);
        if (parent_id != null) {
            var medium = (Camel.Medium) mime;
            /* Forwards keep References / Conversation-ID but not In-Reply-To
             * (that would look like a reply). */
            if (!is_forward)
                medium.set_header ("In-Reply-To", parent_id);
            var refs = unfold_header (reply_of.references);
            if (refs.length == 0)
                refs = unfold_header (reply_of.in_reply_to);
            medium.set_header (
                "References",
                refs.length > 0 ? "%s %s".printf (refs, parent_id) : parent_id
            );
        }

        var topic = unfold_header (reply_of.thread_topic);
        if (topic.length == 0) {
            topic = Conversation.display_subject (reply_of.subject);
            if (topic == _("(No subject)"))
                topic = "";
        }
        if (topic.length > 0)
            ((Camel.Medium) mime).set_header ("Thread-Topic", topic);

        var conversation_id = unfold_header (reply_of.conversation_id);
        if (conversation_id.length > 0)
            ((Camel.Medium) mime).set_header ("Conversation-ID", conversation_id);

        var thread_index = next_thread_index (reply_of.thread_index);
        if (thread_index != null)
            ((Camel.Medium) mime).set_header ("Thread-Index", thread_index);
    }

    private static string? message_id_domain (string address) {
        var at = address.last_index_of_char ('@');
        if (at < 0 || at + 1 >= address.length)
            return null;
        return address.substring (at + 1);
    }

    private static string unfold_header (string? raw) {
        if (raw == null || raw.length == 0)
            return "";

        var builder = new StringBuilder ();
        bool space = false;
        for (int i = 0; i < raw.length; i++) {
            var c = raw[i];
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
                space = true;
                continue;
            }
            if (space && builder.len > 0)
                builder.append_c (' ');
            space = false;
            builder.append_c (c);
        }
        return builder.str;
    }

    private static string compact_header (string? raw) {
        if (raw == null)
            return "";

        var builder = new StringBuilder ();
        for (int i = 0; i < raw.length; i++) {
            var c = raw[i];
            if (c != ' ' && c != '\t' && c != '\r' && c != '\n')
                builder.append_c (c);
        }
        return builder.str;
    }

    private static string? angle_message_id (string? raw) {
        var id = unfold_header (raw);
        if (id.length == 0)
            return null;
        if (id.has_prefix ("<") && id.has_suffix (">"))
            return id;
        return "<%s>".printf (id);
    }

    private const uint64 FILETIME_UNIX_EPOCH = 116444736000000000;

    private static uint64 unix_to_filetime (int64 unix_sec) {
        if (unix_sec < 0)
            unix_sec = 0;
        return ((uint64) unix_sec) * 10000000 + FILETIME_UNIX_EPOCH;
    }

    private static string? next_thread_index (string? parent) {
        var compact = compact_header (parent);
        if (compact.length == 0)
            return null;

        uint8[] decoded = Base64.decode (compact);
        if (decoded.length < 22)
            return null;

        uint64 header_ft = 0;
        for (int i = 0; i < 5; i++)
            header_ft = (header_ft << 8) | decoded[1 + i];
        header_ft <<= 24;

        var now_ft = unix_to_filetime (new DateTime.now_utc ().to_unix ());
        uint64 diff = now_ft > header_ft ? now_ft - header_ft : 0;
        if (diff == 0)
            diff = ((uint64) 1) << 18;

        uint32 packed;
        if (diff < (((uint64) 1) << 49))
            packed = (uint32) ((diff >> 18) & 0x7FFFFFFF);
        else
            packed = (uint32) ((diff >> 23) & 0x7FFFFFFF) | 0x80000000;

        var next = new uint8[decoded.length + 5];
        for (int i = 0; i < decoded.length; i++)
            next[i] = decoded[i];
        var offset = decoded.length;
        next[offset] = (uint8) ((packed >> 24) & 0xFF);
        next[offset + 1] = (uint8) ((packed >> 16) & 0xFF);
        next[offset + 2] = (uint8) ((packed >> 8) & 0xFF);
        next[offset + 3] = (uint8) (packed & 0xFF);
        next[offset + 4] = (uint8) Random.int_range (0, 256);
        return Base64.encode (next);
    }

    private static Camel.DataWrapper build_outgoing_body (
        string plain,
        string? html,
        GenericArray<Attachment>? attachments
    ) {
        var inlines = new GenericArray<Attachment> ();
        var use_html = html;
        if (html != null && html.strip ().length > 0)
            use_html = extract_inline_data_images (html, inlines);

        var has_html = use_html != null && use_html.strip ().length > 0;
        var has_files = attachments != null && attachments.length > 0;
        var has_inline = inlines.length > 0;

        Camel.DataWrapper body;
        if (has_html)
            body = build_alternative (plain, use_html);
        else {
            var text_part = new Camel.MimePart ();
            text_part.set_content (plain.data, "text/plain; charset=UTF-8");
            text_part.set_encoding (Camel.TransferEncoding.ENCODING_8BIT);
            body = text_part;
        }

        if (has_inline)
            body = wrap_related (body, inlines);

        if (!has_files)
            return body;

        var mixed = new Camel.Multipart ();
        mixed.set_mime_type ("multipart/mixed");
        mixed.set_boundary (null);

        var body_part = new Camel.MimePart ();
        ((Camel.Medium) body_part).set_content (body);
        mixed.add_part (body_part);

        for (uint i = 0; i < attachments.length; i++) {
            var attachment = attachments[i];
            if (attachment.inline_part)
                continue;
            var part = new Camel.MimePart ();
            unowned uint8[] data = attachment.data.get_data ();
            var type = attachment.mime_type;
            if (type == null || type.length == 0)
                type = "application/octet-stream";
            part.set_content (data, type);
            part.set_filename (attachment.filename);
            part.set_disposition ("attachment");
            part.set_encoding (Camel.TransferEncoding.ENCODING_BASE64);
            mixed.add_part (part);
        }

        return mixed;
    }

    private static Camel.DataWrapper wrap_related (Camel.DataWrapper body, GenericArray<Attachment> inlines) {
        var related = new Camel.Multipart ();
        related.set_mime_type ("multipart/related");
        related.set_boundary (null);

        var body_part = new Camel.MimePart ();
        ((Camel.Medium) body_part).set_content (body);
        related.add_part (body_part);

        for (uint i = 0; i < inlines.length; i++) {
            var image = inlines[i];
            var part = new Camel.MimePart ();
            unowned uint8[] data = image.data.get_data ();
            var type = image.mime_type;
            if (type == null || type.length == 0)
                type = "image/png";
            part.set_content (data, type);
            if (image.content_id != null && image.content_id.length > 0)
                part.set_content_id (image.content_id);
            if (image.filename != null && image.filename.length > 0)
                part.set_filename (image.filename);
            part.set_disposition ("inline");
            part.set_encoding (Camel.TransferEncoding.ENCODING_BASE64);
            related.add_part (part);
        }

        return related;
    }

    /* Turn data:image…;base64,… HTML into multipart/related CID parts.
     * Graph/Gmail routinely strip raw data-URI images from HTML-only bodies. */
    private static string extract_inline_data_images (string html, GenericArray<Attachment> inlines) {
        var result = new StringBuilder ();
        int cursor = 0;
        uint serial = 0;
        while (cursor < html.length) {
            var start = html.index_of ("data:image/", cursor);
            if (start < 0) {
                result.append (html.substring (cursor));
                break;
            }

            var quote = '\0';
            if (start > 0 && (html[start - 1] == '"' || html[start - 1] == '\''))
                quote = html[start - 1];

            var meta_end = html.index_of (";base64,", start);
            if (meta_end < 0) {
                result.append (html.substring (cursor, start + 11 - cursor));
                cursor = start + 11;
                continue;
            }

            var mime = html.substring (start + 5, meta_end - (start + 5)).strip ();
            var data_start = meta_end + 8; /* ";base64," */
            int data_end;
            if (quote != '\0') {
                data_end = html.index_of_char (quote, data_start);
                if (data_end < 0)
                    data_end = html.length;
            } else {
                data_end = data_start;
                while (data_end < html.length) {
                    var c = html[data_end];
                    if (c == ' ' || c == '\t' || c == '\n' || c == '\r'
                        || c == '"' || c == '\'' || c == '>' || c == ')')
                        break;
                    data_end++;
                }
            }

            var b64 = html.substring (data_start, data_end - data_start)
                .replace ("\n", "")
                .replace ("\r", "")
                .replace (" ", "");
            var raw = Base64.decode (b64);
            if (raw.length == 0) {
                result.append (html.substring (cursor, data_end - cursor));
                cursor = data_end;
                continue;
            }

            serial++;
            var cid = "letter.inline.%u@localhost".printf (serial);
            var ext = "png";
            var mime_down = mime.down ();
            if (mime_down.has_suffix ("jpeg") || mime_down.has_suffix ("jpg"))
                ext = "jpg";
            else if (mime_down.has_suffix ("gif"))
                ext = "gif";
            else if (mime_down.has_suffix ("webp"))
                ext = "webp";
            inlines.add (new Attachment () {
                filename = "image-%u.%s".printf (serial, ext),
                mime_type = mime,
                data = new Bytes (raw),
                content_id = cid,
                inline_part = true,
            });

            result.append (html.substring (cursor, start - cursor));
            result.append ("cid:");
            result.append (cid);
            /* Leave the closing quote / following HTML for the next copy. */
            cursor = data_end;
        }

        if (inlines.length > 0)
            Utils.sync_log ("outgoing inline images: %u CID part(s)".printf (inlines.length));
        return result.str;
    }

    private static Camel.Multipart build_alternative (string plain, string html) {
        var plain_part = new Camel.MimePart ();
        plain_part.set_content (plain.data, "text/plain; charset=UTF-8");
        plain_part.set_encoding (Camel.TransferEncoding.ENCODING_8BIT);

        var html_part = new Camel.MimePart ();
        html_part.set_content (html.data, "text/html; charset=UTF-8");
        html_part.set_encoding (Camel.TransferEncoding.ENCODING_8BIT);

        var multipart = new Camel.Multipart ();
        multipart.set_mime_type ("multipart/alternative");
        multipart.set_boundary (null);
        multipart.add_part (plain_part);
        multipart.add_part (html_part);
        return multipart;
    }

    private async Camel.Transport open_transport (Account account, Cancellable? cancellable) throws Error {
        var source = this.registry.ref_source (account.source_uid);
        if (source == null)
            throw new IOError.NOT_FOUND (_("Mail source “%s” was not found.").printf (account.source_uid));

        var mail_account = (E.SourceMailAccount) source.get_extension (E.SOURCE_EXTENSION_MAIL_ACCOUNT);
        var identity_uid = mail_account.get_identity_uid ();
        E.Source? identity_source = identity_uid != null ? this.registry.ref_source (identity_uid) : null;

        E.Source? submission_source = null;
        if (identity_source != null && identity_source.has_extension (E.SOURCE_EXTENSION_MAIL_SUBMISSION))
            submission_source = identity_source;
        else if (source.has_extension (E.SOURCE_EXTENSION_MAIL_SUBMISSION))
            submission_source = source;

        if (submission_source == null) {
            throw new IOError.NOT_FOUND (
                _("No outgoing server is configured for “%s”.").printf (account.display_name)
            );
        }

        var submission = (E.SourceMailSubmission) submission_source.get_extension (E.SOURCE_EXTENSION_MAIL_SUBMISSION);
        var transport_uid = submission.get_transport_uid ();
        if (transport_uid == null || transport_uid.length == 0) {
            throw new IOError.NOT_FOUND (
                _("No outgoing server is configured for “%s”.").printf (account.display_name)
            );
        }

        var transport_source = this.registry.ref_source (transport_uid);
        if (transport_source == null)
            throw new IOError.NOT_FOUND (_("Mail source “%s” was not found.").printf (transport_uid));

        var transport_ext = (E.SourceMailTransport) transport_source.get_extension (E.SOURCE_EXTENSION_MAIL_TRANSPORT);
        var protocol = transport_ext.get_backend_name ();
        if (protocol == null || protocol.length == 0)
            throw new IOError.FAILED (_("The account has no mail backend."));

        var service = ref_service (transport_uid);
        if (service == null) {
            service = add_service (transport_uid, protocol, Camel.ProviderType.TRANSPORT);
            transport_source.camel_configure_service (service);
        }

        var net = service.ref_settings () as Camel.NetworkSettings;
        var had_user = net != null && net.get_user ().length > 0;
        ensure_service_user (service, account, transport_source);
        net = service.ref_settings () as Camel.NetworkSettings;
        if (net == null || net.get_user ().length == 0) {
            try {
                var store = yield open_store (account, cancellable);
                copy_network_user (store, service);
            } catch (Error store_error) {
                debug ("Could not copy store credentials onto the transport: %s", store_error.message);
            }
        }

        net = service.ref_settings () as Camel.NetworkSettings;
        if (!had_user && net != null && net.get_user ().length > 0
            && service.get_connection_status () == Camel.ServiceConnectionStatus.CONNECTED) {
            try {
                yield service.disconnect (false, Priority.DEFAULT, cancellable);
            } catch (Error disconnect_error) {
                debug ("Could not reset outgoing connection: %s", disconnect_error.message);
            }
        }

        if (service.get_connection_status () != Camel.ServiceConnectionStatus.CONNECTED)
            yield service.connect (Priority.DEFAULT, cancellable);

        return (Camel.Transport) service;
    }

    private static bool backend_saves_sent_on_server (Account account) {
        if (account.kind == AccountKind.MICROSOFT)
            return true;

        var backend = (account.backend_name ?? "").down ();
        return backend == "microsoft365" || backend.contains ("graph");
    }

    private async string? save_to_folder (
        Account account,
        FolderKind kind,
        Camel.MimeMessage mime,
        Cancellable? cancellable,
        out Folder? mail_folder
    ) throws Error {
        mail_folder = null;
        var store = yield open_store (account, cancellable);
        var folder_name = special_folder_name (account, kind);
        Camel.Folder? folder = null;
        Folder? match = null;
        if (folder_name != null) {
            try {
                folder = yield store.get_folder (folder_name, Camel.StoreGetFolderFlags.NONE, Priority.DEFAULT, cancellable);
            } catch (Error e) {
                debug ("Configured special folder “%s” is unavailable: %s", folder_name, e.message);
            }
        }

        var folders = yield list_folders (account, cancellable, false);
        for (uint i = 0; i < folders.length; i++) {
            if (folders[i].kind != kind)
                continue;
            match = folders[i];
            if (folder == null || folders[i].full_name == folder.get_full_name ())
                break;
        }

        if (folder == null && match != null)
            folder = yield store.get_folder (match.full_name, Camel.StoreGetFolderFlags.NONE, Priority.DEFAULT, cancellable);

        if (folder == null) {
            throw new IOError.NOT_FOUND (
                kind == FolderKind.DRAFTS
                    ? _("No Drafts folder was found for this account.")
                    : _("No Sent folder was found for this account.")
            );
        }

        if (match == null) {
            match = new Folder () {
                name = folder.get_full_display_name () ?? folder.get_full_name (),
                full_name = folder.get_full_name (),
                flags = kind == FolderKind.SENT
                    ? (uint) Camel.FolderInfoFlags.TYPE_SENT
                    : (uint) Camel.FolderInfoFlags.TYPE_DRAFTS,
            };
        }

        mail_folder = match;
        string? appended = null;
        /* MessageInfo.@new is missing from some distro VAPIs (e.g. Ubuntu
         * EDS 3.56); FolderSummary.info_new_from_message is widely available. */
        Camel.MessageInfo? info = null;
        var summary = folder.get_folder_summary ();
        if (summary != null) {
            info = summary.info_new_from_message (mime);
            info.set_flags (Camel.MessageFlags.SEEN, Camel.MessageFlags.SEEN);
        }
        yield enter_camel (true);
        try {
            yield folder.append_message (mime, info, Priority.DEFAULT, cancellable, out appended);
        } finally {
            leave_camel (true);
        }

        Utils.sync_log ("saved copy in “%s” uid=%s".printf (
            match.name,
            appended != null && appended.length > 0 ? appended : "?"
        ));
        return appended;
    }

    private async Folder? find_special_folder (Account account, FolderKind kind, Cancellable? cancellable) {
        try {
            var folders = yield list_folders (account, cancellable, false);
            for (uint i = 0; i < folders.length; i++) {
                if (folders[i].kind == kind)
                    return folders[i];
            }
        } catch (Error e) {
            debug ("Could not look up special folder: %s", e.message);
        }
        return null;
    }

    private string? special_folder_name (Account account, FolderKind kind) {
        string? uri = null;
        if (kind == FolderKind.DRAFTS) {
            var source = extension_source (account, E.SOURCE_EXTENSION_MAIL_COMPOSITION);
            if (source != null) {
                var composition = (E.SourceMailComposition) source.get_extension (E.SOURCE_EXTENSION_MAIL_COMPOSITION);
                uri = composition.get_drafts_folder ();
            }
        } else if (kind == FolderKind.SENT) {
            var source = extension_source (account, E.SOURCE_EXTENSION_MAIL_SUBMISSION);
            if (source != null) {
                var submission = (E.SourceMailSubmission) source.get_extension (E.SOURCE_EXTENSION_MAIL_SUBMISSION);
                if (!submission.get_use_sent_folder ())
                    return null;
                uri = submission.get_sent_folder ();
            }
        }

        return folder_name_from_uri (uri);
    }

    private E.Source? extension_source (Account account, string extension) {
        if (account.source_uid == null)
            return null;

        var source = this.registry.ref_source (account.source_uid);
        if (source == null)
            return null;

        var mail_account = (E.SourceMailAccount) source.get_extension (E.SOURCE_EXTENSION_MAIL_ACCOUNT);
        var identity_uid = mail_account.get_identity_uid ();
        if (identity_uid != null) {
            var identity_source = this.registry.ref_source (identity_uid);
            if (identity_source != null && identity_source.has_extension (extension))
                return identity_source;
        }

        return source.has_extension (extension) ? source : null;
    }

    private static string? folder_name_from_uri (string? uri) {
        if (uri == null || uri.strip ().length == 0)
            return null;

        var value = uri.strip ();
        if (value.has_prefix ("folder://")) {
            var rest = value.substring (9);
            var slash = rest.index_of_char ('/');
            if (slash < 0 || slash + 1 >= rest.length)
                return null;
            value = Uri.unescape_string (rest.substring (slash + 1)) ?? rest.substring (slash + 1);
        }

        if (value.length == 0)
            return null;

        var leaf = value;
        var slash = value.last_index_of_char ('/');
        if (slash >= 0 && slash + 1 < value.length)
            leaf = value.substring (slash + 1);

        var down = leaf.down ();
        if (down == "mailfolders" || down == "users" || down == "messages")
            return null;

        return value;
    }

    private static void copy_network_user (Camel.Service from, Camel.Service to) {
        var src = from.ref_settings () as Camel.NetworkSettings;
        var dst = to.ref_settings () as Camel.NetworkSettings;
        if (src == null || dst == null)
            return;

        var user = src.dup_user ();
        if (user != null && user.length > 0 && dst.get_user ().length == 0)
            dst.set_user (user);

        var host = src.dup_host ();
        if (host != null && host.length > 0 && dst.get_host ().length == 0)
            dst.set_host (host);
    }

    private void ensure_service_user (Camel.Service service, Account account, E.Source source) {
        var settings = service.ref_settings () as Camel.NetworkSettings;
        if (settings == null)
            return;

        if (settings.get_user ().length > 0)
            return;

        if (source.has_extension (E.SOURCE_EXTENSION_AUTHENTICATION)) {
            var auth = (E.SourceAuthentication) source.get_extension (E.SOURCE_EXTENSION_AUTHENTICATION);
            var user = auth.get_user ();
            if (user != null && user.length > 0) {
                settings.set_user (user);
                return;
            }
        }

        var parent_uid = source.get_parent ();
        if (parent_uid != null) {
            var parent = this.registry.ref_source (parent_uid);
            if (parent != null && parent.has_extension (E.SOURCE_EXTENSION_AUTHENTICATION)) {
                var auth = (E.SourceAuthentication) parent.get_extension (E.SOURCE_EXTENSION_AUTHENTICATION);
                var user = auth.get_user ();
                if (user != null && user.length > 0) {
                    settings.set_user (user);
                    return;
                }
            }
        }

        var identity = get_identity (account);
        if (identity != null && identity.address.length > 0) {
            settings.set_user (identity.address);
            return;
        }

        if (account.email != null && account.email.length > 0)
            settings.set_user (account.email);
    }

    private static Camel.InternetAddress parse_addresses (string? raw) {
        return Utils.internet_address_from_header (raw);
    }

    private static void ensure_valid_recipients (Camel.InternetAddress addresses) throws Error {
        for (int i = 0; i < addresses.length (); i++) {
            string? name;
            string? email;
            if (!addresses.get (i, out name, out email))
                continue;

            var addr = email != null ? email.strip () : "";
            if (addr.length == 0)
                addr = (name ?? "").strip ();

            if (!is_valid_email (addr)) {
                throw new IOError.INVALID_ARGUMENT (
                    _("“%s” is not a valid email address. Group and personal names need a full address like name@example.com.").printf (
                        addr.length > 0 ? addr : _("recipient")
                    )
                );
            }
        }
    }

    private static bool is_valid_email (string addr) {
        var at = addr.index_of_char ('@');
        if (at <= 0 || at >= addr.length - 1)
            return false;

        var domain = addr.substring (at + 1);
        return domain.index_of_char ('.') > 0 && !addr.contains (" ");
    }
}

public class Mail.Identity : Object {
    public string name { get; set; }
    public string address { get; set; }
    public string[] aliases { get; set; }
}

public class Mail.Attachment : Object {
    public string filename { get; set; }
    public string mime_type { get; set; }
    public Bytes data { get; set; }
    public File? file { get; set; }
    public string? content_id { get; set; }
    public bool inline_part { get; set; }

    public bool is_message {
        get {
            var type = this.mime_type ?? "";
            var name = this.filename ?? "";
            return type.has_prefix ("message/") || name.down ().has_suffix (".eml");
        }
    }

    public string save_filename {
        owned get {
            var name = Path.get_basename (this.filename ?? "");
            if (name.length == 0)
                name = "attachment";
            name = name.replace ("/", "-").replace ("\\", "-");
            if (this.is_message && !name.down ().has_suffix (".eml"))
                name += ".eml";
            return name;
        }
    }

    public string size_label {
        owned get {
            return format_size (this.data.get_size ());
        }
    }
}

public class Mail.Recipient : Object {
    public string name { get; set; default = ""; }
    public string email { get; set; default = ""; }

    public string chip_label {
        owned get {
            var display = Utils.sanitize_recipient_text (this.name);
            var addr = Utils.sanitize_recipient_text (this.email);
            if (display.length > 0 && !display.contains ("@"))
                return display;
            if (display.length > 0 && display.down () != addr.down ())
                return display;
            return addr;
        }
    }

    public string tooltip {
        owned get {
            var display = Utils.sanitize_recipient_text (this.name);
            var addr = Utils.sanitize_recipient_text (this.email);
            if (display.length > 0 && addr.length > 0 && display.down () != addr.down ())
                return "%s <%s>".printf (display, addr);
            if (addr.length > 0)
                return addr;
            return display;
        }
    }
}

public class Mail.MessageContent : Object {
    public string uid { get; set; }
    public string subject { get; set; }
    public string from { get; set; }
    public string? from_email { get; set; }
    public string to { get; set; }
    public string? cc { get; set; }
    public string? bcc { get; set; }
    public GenericArray<Recipient> to_recipients { get; set; }
    public GenericArray<Recipient> cc_recipients { get; set; }
    public GenericArray<Recipient> bcc_recipients { get; set; }
    public int64 date { get; set; }
    public string html { get; set; }
    public string? plain_text { get; set; }
    public bool has_remote_images { get; set; }
    public GenericArray<Attachment> attachments { get; set; }
    public Invitation? invitation { get; set; }
    public string? message_id { get; set; }
    public string? in_reply_to { get; set; }
    public string? references { get; set; }
    public string? thread_index { get; set; }
    public string? thread_topic { get; set; }
    public string? conversation_id { get; set; }
    public bool high_priority { get; set; }

    public static bool mime_has_high_priority (Camel.MimeMessage mime) {
        var medium = (Camel.Medium) mime;
        var importance = (medium.get_header ("Importance") ?? "").strip ().down ();
        if (importance == "high")
            return true;
        var ms = (medium.get_header ("X-MSMail-Priority") ?? "").strip ().down ();
        if (ms == "high")
            return true;
        var priority = (medium.get_header ("Priority") ?? "").strip ().down ();
        if (priority == "urgent")
            return true;
        var x_priority = (medium.get_header ("X-Priority") ?? "").strip ();
        if (x_priority.length > 0) {
            var first = x_priority.get_char (0);
            if (first == '1' || first == '2')
                return true;
        }
        return false;
    }

    public static void apply_priority_headers (Camel.MimeMessage mime, bool high) {
        var medium = (Camel.Medium) mime;
        if (high) {
            medium.set_header ("Importance", "high");
            medium.set_header ("X-Priority", "1");
            medium.set_header ("Priority", "urgent");
            medium.set_header ("X-MSMail-Priority", "High");
            return;
        }
        medium.remove_header ("Importance");
        medium.remove_header ("X-Priority");
        medium.remove_header ("Priority");
        medium.remove_header ("X-MSMail-Priority");
    }

    public static MessageContent from_mime (string uid, Camel.MimeMessage mime) {
        var subject = mime.get_subject ();
        if (subject == null || subject.length == 0)
            subject = _("(No subject)");

        var from_email = Utils.address_email (mime.get_from ());
        var from = Utils.format_internet_address (mime.get_from ());
        if (from.length == 0)
            from = _("Unknown sender");

        var to_list = mime.get_recipients (Camel.RECIPIENT_TYPE_TO);
        var cc_list = mime.get_recipients (Camel.RECIPIENT_TYPE_CC);
        var bcc_list = mime.get_recipients (Camel.RECIPIENT_TYPE_BCC);
        var to = Utils.format_internet_address (to_list);
        var cc = Utils.format_internet_address (cc_list);
        var bcc = Utils.format_internet_address (bcc_list);
        if (cc != null && cc.length == 0)
            cc = null;
        if (bcc != null && bcc.length == 0)
            bcc = null;
        var to_recipients = Utils.recipients_from_address (to_list);
        var cc_recipients = Utils.recipients_from_address (cc_list);
        var bcc_recipients = Utils.recipients_from_address (bcc_list);

        int offset = 0;
        int64 date = (int64) mime.get_date (out offset);
        if (date <= 0)
            date = (int64) mime.get_date_received (out offset);

        string? html = null;
        string? text = null;
        string? calendar = null;
        var images = new HashTable<string, string> (str_hash, str_equal);
        var attachments = new GenericArray<Attachment> ();
        var inside_nested = new HashTable<Camel.MimePart, uint> (direct_hash, direct_equal);

        mime.foreach_part ((message, part, parent) => {
            if (parent != null && (is_opaque_message (parent) || inside_nested.contains (parent))) {
                inside_nested.set (part, 1);
                return true;
            }
            collect_calendar (part, ref calendar);
            collect_body (part, ref html, ref text);
            collect_cid_image (part, images);
            collect_attachment (part, attachments);
            return true;
        });
        if (html == null && text == null)
            collect_body (mime, ref html, ref text);
        if (calendar == null)
            collect_calendar (mime, ref calendar);

        var invitation = CalendarStore.parse (calendar);
        string body;
        if (html != null && html.strip ().length > 0)
            body = rewrite_cids (html, images);
        else if (text != null && text.strip ().length > 0)
            body = text_to_html (text);
        else if (invitation != null)
            body = text_to_html (invitation.fallback_text ());
        else
            body = text_to_html (_("This message has no readable content."));

        return new MessageContent () {
            uid = uid,
            subject = subject,
            from = from,
            from_email = from_email,
            to = to,
            cc = cc,
            bcc = bcc,
            to_recipients = to_recipients,
            cc_recipients = cc_recipients,
            bcc_recipients = bcc_recipients,
            date = date,
            html = body,
            plain_text = text,
            has_remote_images = Utils.html_has_remote_images (body),
            attachments = attachments,
            invitation = invitation,
            message_id = mime.get_message_id (),
            in_reply_to = ((Camel.Medium) mime).get_header ("In-Reply-To"),
            references = ((Camel.Medium) mime).get_header ("References"),
            thread_index = ((Camel.Medium) mime).get_header ("Thread-Index"),
            thread_topic = ((Camel.Medium) mime).get_header ("Thread-Topic"),
            conversation_id = ((Camel.Medium) mime).get_header ("Conversation-ID"),
            high_priority = mime_has_high_priority (mime),
        };
    }

    private static void collect_body (Camel.MimePart part, ref string? html, ref string? text) {
        if (is_file_attachment (part) || is_cid_image (part))
            return;

        var type = part.get_content_type ();
        var wrapper = part.get_content ();
        if (type == null || wrapper == null)
            return;

        if (type.@is ("text", "html") && (html == null || html.length == 0))
            html = decode_part_text (wrapper);
        else if (type.@is ("text", "plain") && (text == null || text.length == 0))
            text = decode_part_text (wrapper);
    }

    private static void collect_cid_image (Camel.MimePart part, HashTable<string, string> images) {
        if (!is_cid_image (part))
            return;

        var bytes = decode_part_bytes (part.get_content ());
        if (bytes == null)
            return;

        var type = part.get_content_type ();
        var mime_type = type != null ? type.simple () : "image/png";
        var data_uri = "data:%s;base64,%s".printf (mime_type, Base64.encode (bytes.get_data ()));
        var cid = strip_cid (part.get_content_id ());
        if (cid.length > 0)
            images.set (cid, data_uri);
    }

    private static void collect_calendar (Camel.MimePart part, ref string? ics) {
        if (ics != null && ics.length > 0)
            return;

        var type = part.get_content_type ();
        var wrapper = part.get_content ();
        if (type == null || wrapper == null)
            return;
        if (!type.@is ("text", "calendar") && !type.@is ("application", "ics"))
            return;

        var text = decode_part_text (wrapper);
        if (text != null && text.contains ("BEGIN:VCALENDAR"))
            ics = text;
    }

    private static void collect_attachment (Camel.MimePart part, GenericArray<Attachment> attachments) {
        if (is_protocol_part (part) || is_cid_image (part))
            return;
        if (!is_opaque_message (part) && !is_file_attachment (part))
            return;

        var type = part.get_content_type ();
        if (type != null && (type.@is ("text", "calendar") || type.@is ("application", "ics")))
            return;

        var bytes = decode_part_bytes (part.get_content ());
        if (bytes == null || bytes.get_size () == 0)
            return;

        attachments.add (new Attachment () {
            filename = attachment_filename (part),
            mime_type = type != null ? type.simple () : "application/octet-stream",
            data = bytes,
        });
    }

    private static bool is_opaque_message (Camel.MimePart part) {
        var type = part.get_content_type ();
        if (type != null && type.@is ("message", "*"))
            return true;

        var filename = part.get_filename ();
        return filename != null && filename.down ().has_suffix (".eml");
    }

    private static bool is_protocol_part (Camel.MimePart part) {
        var type = part.get_content_type ();
        if (type != null
            && (type.@is ("application", "pkcs7-signature")
                || type.@is ("application", "x-pkcs7-signature")
                || type.@is ("application", "pgp-signature")))
            return true;

        var filename = part.get_filename ();
        if (filename == null || filename.length == 0)
            return false;

        var down = filename.down ();
        return down == "smime.p7s"
            || down == "signature.asc"
            || down == "daticert.xml";
    }

    private static string attachment_filename (Camel.MimePart part) {
        if (is_opaque_message (part)) {
            var nested = part as Camel.MimeMessage;
            if (nested == null)
                nested = part.get_content () as Camel.MimeMessage;
            if (nested != null) {
                var subject = nested.get_subject ();
                if (subject != null && subject.strip ().length > 0)
                    return subject.strip ();
            }
        }

        var filename = part.get_filename ();
        if (filename != null && filename.length > 0)
            return filename;

        var type = part.get_content_type ();
        var named = type != null ? type.param ("name") : null;
        if (named != null && named.length > 0)
            return named;

        return is_opaque_message (part) ? _("Forwarded message") : _("Attachment");
    }

    private static bool is_cid_image (Camel.MimePart part) {
        var type = part.get_content_type ();
        var cid = part.get_content_id ();
        return type != null && type.@is ("image", "*") && cid != null && cid.length > 0;
    }

    private static bool is_file_attachment (Camel.MimePart part) {
        var disposition = part.get_disposition ();
        if (disposition != null && disposition.down () == "attachment")
            return true;

        var filename = part.get_filename ();
        if (filename == null || filename.length == 0)
            return false;

        return !is_cid_image (part);
    }

    private static string strip_cid (string? cid) {
        if (cid == null || cid.length == 0)
            return "";

        var builder = new StringBuilder ();
        for (int i = 0; i < cid.length; i++) {
            var ch = cid[i];
            if (ch == '<' || ch == '>')
                continue;
            builder.append_c (ch);
        }
        return builder.str.strip ();
    }

    private static string rewrite_cids (string html, HashTable<string, string> images) {
        var result = html;
        images.foreach ((cid, uri) => {
            if (cid == null || cid.length == 0 || uri == null || uri.length == 0)
                return;
            result = replace_literal (result, "cid:" + cid, uri);
            result = replace_literal (result, "CID:" + cid, uri);
            var unescaped = Uri.unescape_string (cid);
            if (unescaped != null && unescaped.length > 0 && unescaped != cid) {
                result = replace_literal (result, "cid:" + unescaped, uri);
                result = replace_literal (result, "CID:" + unescaped, uri);
            }
        });
        return result;
    }

    /* Vala’s string.replace() builds a GRegex and aborts on RegexError for some
     * real-world MIME cid/data-uri pairs. Keep a plain literal substitute. */
    private static string replace_literal (string text, string old, string replacement) {
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

    private static string decode_part_text (Camel.DataWrapper wrapper) {
        var bytes = decode_part_bytes (wrapper);
        if (bytes == null)
            return "";

        string charset = "utf-8";
        var type = wrapper.get_mime_type_field ();
        if (type != null) {
            var param = type.param ("charset");
            if (param != null && param.length > 0)
                charset = param;
        }

        unowned uint8[] data = bytes.get_data ();
        try {
            return convert ((string) data, data.length, "UTF-8", charset);
        } catch (Error e) {
            return (string) data;
        }
    }

    private static Bytes? decode_part_bytes (Camel.DataWrapper? wrapper) {
        if (wrapper == null)
            return null;

        var output = new MemoryOutputStream.resizable ();
        try {
            wrapper.decode_to_output_stream_sync (output);
            output.close ();
        } catch (Error e) {
            warning ("Could not decode message part: %s", e.message);
            return null;
        }

        var bytes = output.steal_as_bytes ();
        return bytes.get_size () == 0 ? null : bytes;
    }

    public static string text_to_html (string text) {
        var escaped = Markup.escape_text (text).replace ("\n", "<br>\n");
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>%s</body></html>".printf (escaped);
    }
}
