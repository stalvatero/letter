private class Mail.FolderWatch : Object {
    public Camel.Folder? camel_folder;
    public ulong changed_id;
    public string account_key;
    public string folder_name;
    public uint idle;
}

private class Mail.PendingBodyRekey : Object {
    public string account_key;
    public Folder from;
    public string uid;
    public Folder destination;
    public Message candidate;
    public string? resolved_uid;
    public string? body_path;
}

private class Mail.PendingExpunge : Object {
    public string account_key;
    public string folder_full_name;
    public string folder_name;
    public uint folder_flags;
    public string uid;
}

public class Mail.MailSession : Camel.Session {
    public E.SourceRegistry registry { get; construct; }

    private E.CredentialsPrompter prompter;
    private Camel.Service? authenticating_service;
    private string? authenticating_mechanism;
    private HashTable<string, MessageContent> body_cache;
    private GenericArray<FlagFlushJob> flag_flush_queue;
    private HashTable<string, FlagFlushJob> flag_flush_latest;
    private HashTable<string, FlagFlushJob> flag_flush_retries;
    private bool flag_flush_running;
    private GenericArray<TransferFlushJob> transfer_flush_queue;
    private HashTable<string, uint> transfer_pending;
    private bool transfer_flush_running;
    private GenericArray<PendingBodyRekey> pending_body_rekeys;
    private HashTable<string, PendingExpunge> persisted_expunges;
    private HashTable<string, FolderWatch> folder_watches;
    private HashTable<string, int> prefetch_cursor;
    private bool camel_busy;
    private int high_refresh_waiters;

    public const uint PREFETCH_NETWORK_CHUNK = 4;

    public bool header_sync_busy {
        get {
            return this.camel_busy;
        }
    }

    public signal void folder_changed (string account_key, string folder_name);
    public signal void message_sent (Account account, Message? sent);
    public signal void draft_saved (Account account, Message? draft);
    public signal void draft_removed (Account account, Folder folder, string uid);
    public signal void folder_flags_flushed (Account account, Folder folder);
    public signal void transfer_completed (Account account, Folder from, Folder destination);
    public signal void transfer_failed (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        GenericArray<Message>? messages,
        GenericArray<TransferCountChange>? count_changes,
        string error
    );

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
        this.flag_flush_retries = new HashTable<string, FlagFlushJob> (str_hash, str_equal);
        this.transfer_flush_queue = new GenericArray<TransferFlushJob> ();
        this.transfer_pending = new HashTable<string, uint> (str_hash, str_equal);
        this.pending_body_rekeys = new GenericArray<PendingBodyRekey> ();
        this.persisted_expunges = new HashTable<string, PendingExpunge> (str_hash, str_equal);
        this.folder_watches = new HashTable<string, FolderWatch> (str_hash, str_equal);
        this.prefetch_cursor = new HashTable<string, int> (str_hash, str_equal);
        load_pending_sync_state ();
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
        resume_persisted_expunges (account, folders);
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
        public bool expunge;
    }

    private class TransferFlushJob {
        public Account account;
        public Folder from;
        public Folder destination;
        public GenericArray<string> uids;
        public GenericArray<Message>? messages;
        public GenericArray<TransferCountChange>? count_changes;
        public bool delete_original;
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
        bool high = false
    ) throws Error {
        if (cancellable != null && cancellable.is_cancelled ())
            throw new IOError.CANCELLED ("Cancelled");
        if (folder.is_virtual_view)
            return new GenericArray<Message> ();

        var camel_folder = yield open_camel_folder (account, folder, null);
        if (watch)
            watch_camel_folder (account, folder, camel_folder);

        var refreshed = false;
        if (refresh && !folder_has_pending_flags (account, folder)) {
            yield refresh_folder_info (camel_folder, high);
            refreshed = true;
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

        /* A local Camel summary may be stale or incomplete. Only bind an
         * unknown no-COPYUID destination after a successful server refresh. */
        if (refreshed)
            resolve_pending_body_rekeys (account, folder, messages);
        messages = retain_local_only (account, folder, messages, previous);
        retain_pending_transfer_placeholders (account, folder, messages);
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

    public async GenericArray<Message> sync_headers (Account account, Folder folder) throws Error {
        var camel_folder = yield open_camel_folder (account, folder, null);
        watch_camel_folder (account, folder, camel_folder);
        var refreshed = false;
        if (!folder_has_pending_flags (account, folder)) {
            yield refresh_folder_info (
                camel_folder,
                folder.kind == FolderKind.SENT || folder.kind == FolderKind.DRAFTS
            );
            refreshed = true;
        }
        var messages = yield collect_messages (account, camel_folder, folder, null);
        if (refreshed)
            resolve_pending_body_rekeys (account, folder, messages);
        retain_pending_transfer_placeholders (account, folder, messages);
        apply_counts_from_messages (folder, messages);
        return messages;
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
            if (info != null && !message_info_is_deleted (info)) {
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

    public async string? find_matching_uid (
        Account account,
        Folder folder,
        Message candidate,
        Cancellable? cancellable = null
    ) throws Error {
        var camel_folder = yield open_camel_folder (account, folder, cancellable);
        if (folder_has_pending_flags (account, folder))
            return null;
        yield refresh_folder_info (camel_folder, true);
        var messages = yield collect_messages (account, camel_folder, folder, cancellable);
        return matching_message_uid (messages, candidate);
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

    private static bool message_info_is_deleted (Camel.MessageInfo? info) {
        return info != null
            && (info.get_flags () & Camel.MessageFlags.DELETED) != 0;
    }

    /* Camel keeps messages in its summary after \Deleted is set and removes
     * them only after EXPUNGE. Never expose those pending-deletion entries as
     * ordinary mail or include them in Letter's visible folder counts. */
    private static GenericArray<string> folder_visible_uids (Camel.Folder camel_folder) {
        var raw = folder_list_uids (camel_folder);
        var visible = new GenericArray<string> ();
        for (uint i = 0; i < raw.length; i++) {
            var info = camel_folder.get_message_info (raw[i]);
            if (info == null || message_info_is_deleted (info))
                continue;
            visible.add (raw[i]);
        }
        return visible;
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

    public static bool folder_is_under (Folder folder, Folder? root) {
        if (root == null)
            return false;

        var name = folder.full_name;
        var base_name = root.full_name;
        if (name.length == 0 || base_name.length == 0)
            return false;
        if (name == base_name)
            return true;

        return name.has_prefix (base_name + "/")
            || name.has_prefix (base_name + ".")
            || name.has_prefix (base_name + "\\");
    }

    public static bool folder_is_inbox_tree (Folder folder, Folder? inbox) {
        if (folder.watch_new_mail || folder.kind == FolderKind.INBOX)
            return true;
        if (inbox == null)
            return false;

        var name = folder.full_name;
        var root = inbox.full_name;
        if (name.length == 0 || root.length == 0)
            return false;
        if (name == root)
            return true;

        return name.has_prefix (root + "/")
            || name.has_prefix (root + ".")
            || name.has_prefix (root + "\\");
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
            folder.total = remote_total;
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

        while (this.camel_busy || (!high && this.high_refresh_waiters > 0)) {
            Timeout.add (high ? 20 : 80, enter_camel.callback);
            yield;
        }

        this.camel_busy = true;
    }

    private void leave_camel (bool high) {
        this.camel_busy = false;
        if (high)
            this.high_refresh_waiters--;
    }

    private async void refresh_folder_info (Camel.Folder camel_folder, bool high) throws Error {
        yield enter_camel (high);
        try {
            var name = camel_folder.get_full_display_name () ?? camel_folder.get_full_name ();
            var t0 = Utils.sync_tick ();
            /* Do not call prepare_content_refresh(): on Microsoft 365 that
             * clears the Graph delta cursor and forces a full folder walk
             * (minutes on Sent/Archive). Outlook keeps the cursor and only
             * asks for changes. Camel refresh_info already uses delta. */
            yield camel_folder.refresh_info (high ? Priority.DEFAULT : Priority.LOW, null);
            Utils.sync_log ("Camel refresh_info “%s” %s %s".printf (
                name,
                high ? "HIGH" : "LOW",
                Utils.sync_ms (t0)
            ));
        } catch (Error e) {
            Utils.sync_log ("Camel refresh_info FAILED: %s".printf (e.message));
            warning ("Could not refresh folder: %s", e.message);
            throw e;
        } finally {
            leave_camel (high);
        }
    }

    private async Camel.MimeMessage? fetch_camel_message (
        Camel.Folder camel_folder,
        string uid,
        int io_priority
    ) throws Error {
        var high = io_priority < Priority.LOW;
        yield enter_camel (high);
        try {
            return yield camel_folder.get_message (uid, io_priority, null);
        } finally {
            leave_camel (high);
        }
    }

    public async void refresh_folder_counts (
        Account account,
        GenericArray<Folder> folders,
        Cancellable? cancellable = null
    ) throws Error {
        if (account.kind == AccountKind.LOCAL)
            return;

        var store = yield open_store (account, cancellable);
        var flags = Camel.StoreGetFolderInfoFlags.RECURSIVE
            | Camel.StoreGetFolderInfoFlags.SUBSCRIBED
            | Camel.StoreGetFolderInfoFlags.NO_VIRTUAL
            | Camel.StoreGetFolderInfoFlags.REFRESH;
        yield enter_camel (false);
        Camel.FolderInfo? info = null;
        try {
            info = yield store.get_folder_info (null, flags, Priority.DEFAULT, cancellable);
        } finally {
            leave_camel (false);
        }
        var by_name = new HashTable<string, Folder> (str_hash, str_equal);
        for (uint i = 0; i < folders.length; i++)
            by_name.set (folders[i].full_name, folders[i]);
        apply_info_counts (info, by_name);
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

    private static void apply_info_counts (Camel.FolderInfo? info, HashTable<string, Folder> by_name) {
        unowned Camel.FolderInfo? cursor = info;
        while (cursor != null) {
            var folder = by_name.get (cursor.full_name);
            if (folder != null) {
                if (cursor.unread >= 0)
                    folder.unread = cursor.unread;
                if (cursor.total >= 0)
                    folder.total = cursor.total;
            }

            apply_info_counts (cursor.child, by_name);
            cursor = cursor.next;
        }
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
        var uids = folder_visible_uids (camel_folder);
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
        var uids = folder_visible_uids (camel_folder);
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
        var uids = folder_visible_uids (camel_folder);
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

    private GenericArray<Message> retain_local_only (
        Account account,
        Folder folder,
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

        var claimed = new HashTable<string, uint8> (str_hash, str_equal);
        var added = false;
        for (uint i = 0; i < previous.length; i++) {
            var message = previous[i];
            if (!message.is_placeholder)
                continue;
            if (have_uid.contains (message.uid))
                continue;
            var replacement = matching_live_transfer (live, message, claimed);
            if (replacement != null) {
                rekey_body (account, folder, message.uid, folder, replacement.uid);
                claimed.set (replacement.uid, 1);
                continue;
            }
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

    public void retain_pending_transfer_placeholders (
        Account account,
        Folder folder,
        GenericArray<Message> live
    ) {
        var account_key = account.source_uid ?? account.uid;
        var have_uid = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < live.length; i++)
            have_uid.set (live[i].uid, 1);

        var added = false;
        for (uint i = 0; i < this.pending_body_rekeys.length; i++) {
            var pending = this.pending_body_rekeys[i];
            if (pending.account_key != account_key
                || pending.destination.full_name != folder.full_name
                || pending.resolved_uid != null
                || !(pending.candidate.uid.has_prefix ("local-move-")
                    || pending.candidate.uid.has_prefix ("local-copy-"))
                || have_uid.contains (pending.candidate.uid))
                continue;

            /* A completed bulk move without COPYUID can outlive the window
             * that created its optimistic destination row. Restore the row
             * from the durable rekey journal until a full folder summary can
             * identify the real destination UID. */
            Conversation.apply_folder (pending.candidate, folder, pending.candidate.uid);
            pending.candidate.local_only = true;
            live.add (pending.candidate);
            have_uid.set (pending.candidate.uid, 1);
            added = true;
        }
        if (added) {
            live.sort ((a, b) => {
                if (a.date < b.date)
                    return 1;
                if (a.date > b.date)
                    return -1;
                return 0;
            });
        }
    }

    private void resolve_pending_body_rekeys (
        Account account,
        Folder folder,
        GenericArray<Message> live
    ) {
        var account_key = account.source_uid ?? account.uid;
        var claimed = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < this.pending_body_rekeys.length; i++) {
            var pending = this.pending_body_rekeys[i];
            if (pending.account_key == account_key
                && pending.destination.full_name == folder.full_name
                && pending.resolved_uid != null)
                claimed.set (pending.resolved_uid, 1);
        }
        var changed = false;
        for (int i = (int) this.pending_body_rekeys.length - 1; i >= 0; i--) {
            var pending = this.pending_body_rekeys[i];
            if (pending.account_key != account_key
                || pending.destination.full_name != folder.full_name
                || pending.resolved_uid != null)
                continue;

            var replacement = matching_live_transfer (live, pending.candidate, claimed);
            if (replacement == null)
                continue;
            var copy = pending.candidate.uid.has_prefix ("local-copy-");
            if (copy) {
                /* Copies retain their source body. Only promote a body that
                 * was opened under the destination placeholder. */
                rekey_body (
                    account,
                    folder,
                    pending.candidate.uid,
                    folder,
                    replacement.uid
                );
            } else {
                rekey_body (account, pending.from, pending.uid, folder, replacement.uid);
            }
            claimed.set (replacement.uid, 1);
            for (int j = (int) live.length - 1; j >= 0; j--) {
                if (live[j].is_placeholder
                    && live[j].uid == pending.candidate.uid)
                    live.remove_index (j);
            }
            pending.resolved_uid = replacement.uid;
            /* A copy has no recovery snapshot because its source remains in
             * place. Keep that source→destination mapping until Camel has
             * durably cached the destination body. */
            if (pending.body_path == null && !copy)
                this.pending_body_rekeys.remove_index (i);
            changed = true;
        }
        if (changed)
            save_pending_sync_state ();
    }

    private bool folder_has_pending_body_rekeys (Account account, Folder folder) {
        var account_key = account.source_uid ?? account.uid;
        for (uint i = 0; i < this.pending_body_rekeys.length; i++) {
            var pending = this.pending_body_rekeys[i];
            if (pending.account_key == account_key
                && pending.destination.full_name == folder.full_name
                && pending.resolved_uid == null)
                return true;
        }
        return false;
    }

    private PendingBodyRekey? pending_body_rekey (
        Account account,
        Folder folder,
        string uid
    ) {
        var account_key = account.source_uid ?? account.uid;
        for (uint i = 0; i < this.pending_body_rekeys.length; i++) {
            var pending = this.pending_body_rekeys[i];
            if (pending.account_key == account_key
                && pending.destination.full_name == folder.full_name
                && (pending.resolved_uid == uid || pending.candidate.uid == uid))
                return pending;
        }
        return null;
    }

    public bool has_pending_transfer (
        Account account,
        Folder folder,
        string candidate_uid
    ) {
        return pending_body_rekey (account, folder, candidate_uid) != null;
    }

    public void discard_pending_transfer (
        Account account,
        Folder folder,
        string candidate_uid
    ) {
        var pending = pending_body_rekey (account, folder, candidate_uid);
        if (pending != null)
            finish_body_rekey (pending);
    }

    private void finish_body_rekey (PendingBodyRekey pending) {
        for (int i = (int) this.pending_body_rekeys.length - 1; i >= 0; i--) {
            if (this.pending_body_rekeys[i] != pending)
                continue;
            this.pending_body_rekeys.remove_index (i);
            discard_pending_body (pending);
            save_pending_sync_state ();
            return;
        }
    }

    private static string pending_body_cache_dir () {
        return Path.build_filename (
            Environment.get_user_data_dir (),
            "letter",
            "pending-bodies"
        );
    }

    private static string pending_body_cache_file (PendingBodyRekey pending) {
        var identity = "%s\n%s\n%s\n%s".printf (
            pending.account_key,
            pending.from.full_name,
            pending.uid,
            pending.destination.full_name
        );
        return Path.build_filename (
            pending_body_cache_dir (),
            Checksum.compute_for_string (ChecksumType.SHA256, identity) + ".eml"
        );
    }

    private void persist_pending_body (
        PendingBodyRekey pending,
        Camel.MimeMessage mime
    ) {
        var path = pending_body_cache_file (pending);
        try {
            File.new_for_path (pending_body_cache_dir ()).make_directory_with_parents ();
        } catch (Error e) {
            if (!(e is IOError.EXISTS)) {
                warning ("Could not create pending body cache: %s", e.message);
                return;
            }
        }
        try {
            var output = File.new_for_path (path).replace (
                null,
                false,
                FileCreateFlags.REPLACE_DESTINATION,
                null
            );
            mime.write_to_output_stream_sync (output, null);
            output.close (null);
            pending.body_path = path;
        } catch (Error e) {
            warning ("Could not preserve moved message body: %s", e.message);
        }
    }

    private static Camel.MimeMessage? load_pending_body (PendingBodyRekey pending) {
        if (pending.body_path == null || !FileUtils.test (pending.body_path, FileTest.IS_REGULAR))
            return null;
        try {
            var input = File.new_for_path (pending.body_path).read (null);
            var mime = new Camel.MimeMessage ();
            mime.construct_from_input_stream_sync (input, null);
            input.close (null);
            return mime;
        } catch (Error e) {
            warning ("Could not restore moved message body: %s", e.message);
            return null;
        }
    }

    private static void discard_pending_body (PendingBodyRekey pending) {
        if (pending.body_path == null)
            return;
        try {
            File.new_for_path (pending.body_path).delete ();
        } catch (Error e) {
            if (!(e is IOError.NOT_FOUND))
                debug ("Could not remove completed moved body: %s", e.message);
        }
        pending.body_path = null;
    }

    private static Message? matching_live_transfer (
        GenericArray<Message> live,
        Message candidate,
        HashTable<string, uint8> claimed
    ) {
        Message? match = null;
        for (uint i = 0; i < live.length; i++) {
            var message = live[i];
            if (message.is_placeholder || claimed.contains (message.uid))
                continue;

            var same = candidate.msgid_hash != 0
                ? message.msgid_hash == candidate.msgid_hash
                : Conversation.same_outgoing_send (message, candidate)
                    || (message.subject == candidate.subject
                        && message.from == candidate.from
                        && message.to == candidate.to
                        && message.date == candidate.date);
            if (!same)
                continue;
            /* Without COPYUID there is no safe way to choose between duplicate
             * destination messages. Keep the body under its local/source key
             * until a later refresh provides an unambiguous match. */
            if (match != null)
                return null;
            match = message;
        }
        return match;
    }

    public static string? matching_message_uid (
        GenericArray<Message> messages,
        Message candidate
    ) {
        var claimed = new HashTable<string, uint8> (str_hash, str_equal);
        var match = matching_live_transfer (messages, candidate, claimed);
        return match != null ? match.uid : null;
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
            if (info == null || message_info_is_deleted (info)) {
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
        var uids = folder_visible_uids (watch.camel_folder);
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
        var requested_key = body_key (account, folder, uid);
        var pending = pending_body_rekey (account, folder, uid);
        var load_uid = pending != null && pending.resolved_uid != null
            ? pending.resolved_uid
            : uid;
        var key = body_key (account, folder, load_uid);
        var cached = this.body_cache.get (key) ?? this.body_cache.get (requested_key);
        if (cached != null && (pending == null || pending.resolved_uid == null))
            return cached;

        var has_unresolved_rekey = folder_has_pending_body_rekeys (account, folder);
        var defer_online = pending != null || has_unresolved_rekey;
        var camel_folder = yield open_camel_folder (account, folder, null, !defer_online);
        if (has_unresolved_rekey) {
            /* A singleton candidate cannot establish uniqueness: the folder
             * may already contain another message with the same Message-ID or
             * fallback fingerprint. Resolve only after a successful online
             * refresh; an offline/local summary is not authoritative. */
            try {
                var requested_pending = pending;
                camel_folder = yield open_camel_folder (account, folder, cancellable, true);
                yield refresh_folder_info (camel_folder, true);
                var live = yield collect_messages (account, camel_folder, folder, cancellable);
                resolve_pending_body_rekeys (account, folder, live);
                pending = pending_body_rekey (account, folder, uid);
                if (pending == null && requested_pending != null
                    && requested_pending.resolved_uid != null)
                    pending = requested_pending;
            } catch (Error e) {
                if (cancellable != null && cancellable.is_cancelled ())
                    throw e;
                debug ("Could not refresh pending moved message %s: %s", uid, e.message);
            }
            load_uid = pending != null && pending.resolved_uid != null
                ? pending.resolved_uid
                : uid;
            key = body_key (account, folder, load_uid);
            cached = this.body_cache.get (key) ?? this.body_cache.get (requested_key);
        }
        var mime = message_from_local_cache (camel_folder, load_uid);
        var destination_cached = mime != null;
        if (destination_cached && pending != null) {
            finish_body_rekey (pending);
            pending = null;
        }
        if (cached != null)
            return cached;
        if (mime != null) {
            Utils.sync_log ("open body “%s” uid=%s from disk".printf (folder.name, uid));
        } else if (pending != null) {
            /* A no-COPYUID move can leave the only offline copy outside the
             * destination cache. Keep the durable MIME snapshot and mapping
             * until Camel also has the body under the destination UID. */
            mime = load_pending_body (pending);
            if (mime == null) {
                try {
                    var source = yield open_camel_folder (account, pending.from, cancellable, false);
                    mime = message_from_local_cache (source, pending.uid);
                } catch (Error e) {
                    debug ("Could not open moved body cache for %s: %s", uid, e.message);
                }
            }
            if (mime != null)
                Utils.sync_log ("open body “%s” uid=%s from moved disk cache".printf (folder.name, load_uid));
        }
        if (mime == null) {
            if (pending != null && pending.resolved_uid == null) {
                throw new IOError.NOT_FOUND (
                    _("This message is still syncing with the server. Try again in a moment.")
                );
            }
            if (defer_online)
                camel_folder = yield open_camel_folder (account, folder, cancellable, true);
            Utils.sync_log ("open body “%s” uid=%s from server".printf (folder.name, load_uid));
            try {
                mime = yield fetch_camel_message (camel_folder, load_uid, Priority.DEFAULT);
                destination_cached = message_from_local_cache (camel_folder, load_uid) != null;
            } catch (Error e) {
                mime = message_from_local_cache (camel_folder, load_uid);
                destination_cached = mime != null;
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

        var fetched = MessageContent.from_mime (load_uid, mime);
        this.body_cache.set (key, fetched);
        if (pending != null && destination_cached)
            finish_body_rekey (pending);
        return fetched;
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
            if (info != null && !info_has_active_followup (info) && !info.get_folder_flagged ()) {
                try {
                    yield refresh_folder_info (camel_folder, true);
                } catch (Error e) {
                    /* Scheduled auto-marking already updated the UI. Preserve
                     * the prior best-effort behavior and queue the local SEEN
                     * flag instead of leaving client/server state split. */
                    debug ("Could not refresh Microsoft flags before marking read: %s", e.message);
                }
            }
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
        if (folder.kind == FolderKind.JUNK || folder.kind == FolderKind.TRASH)
            return 0;

        int64 cutoff = body_cache_cutoff (days);
        var camel_folder = yield open_camel_folder (account, folder, null);
        var cursor_key = prefetch_cursor_key (account, folder);
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
                try {
                    /* Downloads to Camel’s on-disk cache and drops the in-memory
                     * MimeMessage inside Camel — unlike get_message() to Vala. */
                    yield camel_folder.synchronize_message (message.uid, Priority.LOW, cancellable);
                    stored++;
                } finally {
                    leave_camel (false);
                }
            } catch (Error e) {
                if (e is IOError.CANCELLED)
                    throw e;
            }

            Idle.add (prefetch_recent.callback);
            yield;
        }

        var reached_end = i >= (int) listed.length
            || (cutoff > 0 && i < (int) listed.length && listed[i].date > 0 && listed[i].date < cutoff);
        this.prefetch_cursor.set (cursor_key, reached_end ? 0 : i);

        if (stored > 0 || skipped_disk > 0) {
            Utils.sync_log ("prefetch “%s” done %s from-server=%u skipped-disk=%u cursor=%d/%u".printf (
                folder.name,
                Utils.sync_ms (t0),
                stored,
                skipped_disk,
                reached_end ? 0 : i,
                listed.length
            ));
        }

        /* Camel/SQLite and glibc keep arenas warm across thousands of MIME parses. */
        Camel.DB.release_cache_memory ();
        trim_process_heap ();
        return stored;
    }

    public void reset_prefetch_progress (Account? account = null) {
        if (account == null) {
            this.prefetch_cursor.remove_all ();
            return;
        }
        var prefix = "%s\n".printf (account.source_uid ?? account.uid);
        var keys = new GenericArray<string> ();
        this.prefetch_cursor.foreach ((key, value) => {
            if (key.has_prefix (prefix))
                keys.add (key);
        });
        for (uint i = 0; i < keys.length; i++)
            this.prefetch_cursor.remove (keys[i]);
    }

    private static string prefetch_cursor_key (Account account, Folder folder) {
        return "%s\n%s".printf (account.source_uid ?? account.uid, folder.full_name);
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
        if (days <= 0 || folder.kind == FolderKind.JUNK || folder.kind == FolderKind.TRASH)
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
        var local_mime = yield capture_local_body (account, from, uid, source_folder);
        Message? body_candidate = null;
        var info = source_folder.get_message_info (uid);
        if (info != null) {
            var outgoing = from.kind == FolderKind.SENT
                || from.kind == FolderKind.DRAFTS
                || from.kind == FolderKind.OUTBOX;
            body_candidate = message_from_info (account, uid, info, from, outgoing, source_folder);
            /* The source UID cannot identify a row in the destination after a
             * no-COPYUID move. Give recovery a distinct destination identity
             * while retaining the real source UID in PendingBodyRekey. */
            body_candidate.uid = "local-move-%s".printf (Uuid.string_random ());
            body_candidate.local_only = true;
            var cached = peek_body (account, from, uid);
            if (body_candidate.msgid_hash == 0 && cached != null
                && cached.message_id != null && cached.message_id.length > 0)
                body_candidate.msgid_hash = hash_message_id (cached.message_id, true);
        }
        PendingBodyRekey? pending_rekey = null;
        if (body_candidate != null && peek_body (account, from, uid) != null) {
            pending_rekey = new PendingBodyRekey () {
                account_key = account.source_uid ?? account.uid,
                from = from,
                uid = uid,
                destination = destination,
                candidate = body_candidate,
            };
            if (local_mime != null)
                persist_pending_body (pending_rekey, local_mime);
        }
        var uids = new GenericArray<string> ();
        uids.add (uid);
#if HAVE_CAMEL_3_58
        GenericArray<weak string>? transferred = null;
#else
        GenericArray<string>? transferred = null;
#endif
        var copy_completed = false;
        yield enter_camel (true);
        try {
            yield source_folder.transfer_messages_to (uids, dest_folder, true, Priority.DEFAULT, cancellable, out transferred);
            copy_completed = true;
            /* IMAP servers without UID MOVE implement this as COPY plus a
             * local \Deleted flag. Push and expunge that source-side flag now. */
            yield source_folder.synchronize (true, Priority.DEFAULT, cancellable);
        } catch (Error e) {
            if (!copy_completed) {
                if (pending_rekey != null)
                    discard_pending_body (pending_rekey);
                throw e;
            }
            /* The destination copy already exists and the source is locally
             * marked \Deleted. Treat the move as pending so callers cannot
             * repeat the copy while a later flush retries only EXPUNGE. */
            warning ("Could not expunge moved message: %s", e.message);
            enqueue_flag_flush (account, from, uids, true);
        } finally {
            leave_camel (true);
        }
        string? new_uid = null;
        if (transferred != null && transferred.length > 0 && transferred[0] != null && transferred[0].length > 0)
            new_uid = transferred[0];
        if (new_uid != null) {
            if (pending_rekey != null)
                discard_pending_body (pending_rekey);
            rekey_body (account, from, uid, destination, new_uid);
        } else if (pending_rekey != null) {
            /* Servers without COPYUID cannot identify the destination body key
             * yet. Reconcile it once that folder exposes one unique matching
             * header, retaining the source-keyed body in the meantime. */
            this.pending_body_rekeys.add (pending_rekey);
            save_pending_sync_state ();
        }
        apply_camel_counts (from, source_folder);
        apply_camel_counts (destination, dest_folder);
        return new_uid ?? "";
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
            yield source_folder.transfer_messages_to (uids, dest_folder, false, Priority.DEFAULT, cancellable, out transferred);
        } finally {
            leave_camel (true);
        }
        string? new_uid = null;
        if (transferred != null && transferred.length > 0 && transferred[0] != null && transferred[0].length > 0)
            new_uid = transferred[0];
        apply_camel_counts (from, source_folder);
        apply_camel_counts (destination, dest_folder);
        return new_uid ?? "";
    }

    public void enqueue_move_messages (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        GenericArray<Message>? messages,
        GenericArray<TransferCountChange>? count_changes = null
    ) {
        if (uids.length == 0)
            return;

        var job = new TransferFlushJob () {
            account = account,
            from = from,
            destination = destination,
            uids = uids,
            messages = messages,
            count_changes = count_changes,
            delete_original = true,
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
        /* The undo window has already expired by the time this is called. Do
         * not wait for the next periodic sync to make the server-side move. */
        pump_transfer_flush.begin ();
    }

    /* Copy without removing from source (Gmail Important label). Deferred like moves. */
    public void enqueue_copy_messages (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        GenericArray<Message>? messages,
        GenericArray<TransferCountChange>? count_changes = null
    ) {
        if (uids.length == 0)
            return;

        var job = new TransferFlushJob () {
            account = account,
            from = from,
            destination = destination,
            uids = uids,
            messages = messages,
            count_changes = count_changes,
            delete_original = false,
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
        pump_transfer_flush.begin ();
    }

    /* Push deferred flag/move/copy jobs (call from sync-interval / manual refresh). */
    public async void flush_pending_local_changes () {
        stage_flag_flush_retries ();
        if (this.flag_flush_queue.length > 0)
            Utils.sync_log ("flushing deferred flags (%u queue)".printf (this.flag_flush_queue.length));
        if (this.transfer_flush_queue.length > 0)
            Utils.sync_log ("flushing deferred transfers (%u queue)".printf (this.transfer_flush_queue.length));
        pump_flag_flush.begin ();
        pump_transfer_flush.begin ();

        /* begin() is used during normal operation, but shutdown must be able
         * to wait until both in-memory queues have actually drained. A failed
         * EXPUNGE may return to the retry table; those jobs are journaled when
         * queued and restored on the next account-folder load. */
        while (this.flag_flush_running || this.transfer_flush_running
            || this.flag_flush_queue.length > 0 || this.transfer_flush_queue.length > 0) {
            Timeout.add (50, flush_pending_local_changes.callback);
            yield;
            if (!this.flag_flush_running && this.flag_flush_queue.length > 0)
                pump_flag_flush.begin ();
            if (!this.transfer_flush_running && this.transfer_flush_queue.length > 0)
                pump_transfer_flush.begin ();
        }
    }

    public async void delete_message (Account account, Folder folder, string uid, Folder? trash, Cancellable? cancellable = null) throws Error {
        if (trash != null && folder.full_name != trash.full_name) {
            yield move_message (account, folder, uid, trash, cancellable);
            return;
        }

        var camel_folder = yield open_camel_folder (account, folder, cancellable);
        camel_folder.set_message_flags (uid, Camel.MessageFlags.DELETED, Camel.MessageFlags.DELETED);
        try {
            yield enter_camel (true);
            try {
                /* Permanent delete is a flag upload followed by EXPUNGE.
                 * synchronize_message() only downloads a body for offline use. */
                yield camel_folder.synchronize (true, Priority.DEFAULT, cancellable);
            } finally {
                leave_camel (true);
            }
        } catch (Error e) {
            /* Keep the local summary usable when the server rejected the
             * operation, and let the caller restore its optimistic UI state. */
            camel_folder.set_message_flags (uid, Camel.MessageFlags.DELETED, 0);
            warning ("Could not expunge deleted message: %s", e.message);
            throw e;
        }
        drop_body (account, folder, uid);
        apply_camel_counts (folder, camel_folder);
        if (folder.kind == FolderKind.DRAFTS)
            draft_removed (account, folder, uid);
    }

    public async void delete_uids (Account account, Folder folder, GenericArray<string> uids, Folder? trash) throws Error {
        if (uids.length == 0)
            return;
        if (trash != null && folder.full_name != trash.full_name) {
            enqueue_move_messages (account, folder, trash, uids, null);
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
            }
        } finally {
            camel_folder.thaw ();
        }
        try {
            yield enter_camel (true);
            try {
                yield camel_folder.synchronize (true, Priority.DEFAULT, null);
            } finally {
                leave_camel (true);
            }
        } catch (Error e) {
            camel_folder.freeze ();
            try {
                for (uint i = 0; i < uids.length; i++)
                    camel_folder.set_message_flags (uids[i], Camel.MessageFlags.DELETED, 0);
            } finally {
                camel_folder.thaw ();
            }
            apply_camel_counts (folder, camel_folder);
            throw e;
        }
        for (uint i = 0; i < uids.length; i++)
            drop_body (account, folder, uids[i]);
        apply_camel_counts (folder, camel_folder);
    }

    public async void empty_folder (Account account, Folder folder) throws Error {
        if (folder.is_virtual_view)
            return;

        var camel_folder = yield open_camel_folder (account, folder, null);
        var raw = folder_list_uids (camel_folder);
        if (raw.length == 0) {
            folder.unread = 0;
            folder.total = 0;
            return;
        }

        var uids = new GenericArray<string> ();
        var newly_deleted = new GenericArray<string> ();
        camel_folder.freeze ();
        try {
            for (uint i = 0; i < raw.length; i++) {
                var flags = camel_folder.get_message_flags (raw[i]);
                if ((flags & Camel.MessageFlags.DELETED) == 0) {
                    camel_folder.set_message_flags (
                        raw[i],
                        Camel.MessageFlags.DELETED,
                        Camel.MessageFlags.DELETED
                    );
                    newly_deleted.add (raw[i]);
                }
                uids.add (raw[i]);
            }
        } finally {
            camel_folder.thaw ();
        }
        try {
            yield enter_camel (true);
            try {
                yield camel_folder.synchronize (true, Priority.DEFAULT, null);
            } finally {
                leave_camel (true);
            }
        } catch (Error e) {
            camel_folder.freeze ();
            try {
                for (uint i = 0; i < newly_deleted.length; i++)
                    camel_folder.set_message_flags (newly_deleted[i], Camel.MessageFlags.DELETED, 0);
            } finally {
                camel_folder.thaw ();
            }
            apply_camel_counts (folder, camel_folder);
            throw e;
        }
        for (uint i = 0; i < uids.length; i++)
            drop_body (account, folder, uids[i]);
        folder.unread = 0;
        folder.total = 0;
    }

    public async void set_folder_seen (Account account, Folder folder, bool seen) throws Error {
        var camel_folder = yield open_camel_folder (account, folder, null);
        var raw = folder_visible_uids (camel_folder);
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

    private static string pending_sync_state_file () {
        return Path.build_filename (
            Environment.get_user_data_dir (),
            "letter",
            "pending-sync-state"
        );
    }

    private static string pending_sync_group (string kind, string identity) {
        return "%s-%s".printf (
            kind,
            Checksum.compute_for_string (ChecksumType.SHA256, identity)
        );
    }

    private void load_pending_sync_state () {
        var path = pending_sync_state_file ();
        if (!FileUtils.test (path, FileTest.IS_REGULAR))
            return;

        var state = new KeyFile ();
        try {
            state.load_from_file (path, KeyFileFlags.NONE);
        } catch (Error e) {
            warning ("Could not read pending mail synchronization state: %s", e.message);
            return;
        }

        foreach (var group in state.get_groups ()) {
            try {
                if (group.has_prefix ("expunge-")) {
                    var pending = new PendingExpunge () {
                        account_key = state.get_string (group, "account"),
                        folder_full_name = state.get_string (group, "folder"),
                        folder_name = state.get_string (group, "folder-name"),
                        folder_flags = (uint) state.get_uint64 (group, "folder-flags"),
                        uid = state.get_string (group, "uid"),
                    };
                    this.persisted_expunges.set (
                        "%s\n%s".printf (pending.account_key, pending.folder_full_name),
                        pending
                    );
                    continue;
                }
                if (!group.has_prefix ("body-"))
                    continue;

                var from_name = state.get_string (group, "from-name");
                var from_full_name = state.get_string (group, "from-folder");
                var destination_name = state.get_string (group, "destination-name");
                var destination_full_name = state.get_string (group, "destination-folder");
                var outgoing = state.get_boolean (group, "outgoing");
                var stored_uid = state.get_string (group, "uid");
                var stored_candidate_uid = state.has_key (group, "candidate-uid")
                    ? state.get_string (group, "candidate-uid")
                    : stored_uid;
                var candidate_uid = stored_candidate_uid;
                if (stored_candidate_uid.has_prefix ("local-move-")) {
                    candidate_uid = "local-move-pending-%s".printf (
                        group.substring ("body-".length)
                    );
                } else if (stored_candidate_uid.has_prefix ("local-copy-")) {
                    candidate_uid = "local-copy-pending-%s".printf (
                        group.substring ("body-".length)
                    );
                }
                string? resolved_uid = null;
                if (state.has_key (group, "resolved-uid")) {
                    var stored = state.get_string (group, "resolved-uid");
                    if (stored.length > 0)
                        resolved_uid = stored;
                }
                var candidate = new Message () {
                    uid = candidate_uid,
                    subject = state.get_string (group, "subject"),
                    from = state.get_string (group, "from"),
                    to = state.get_string (group, "to"),
                    cc = state.has_key (group, "cc") ? state.get_string (group, "cc") : "",
                    date = state.get_int64 (group, "date"),
                    outgoing = outgoing,
                    seen = state.has_key (group, "seen") && state.get_boolean (group, "seen"),
                    flagged = state.has_key (group, "flagged") && state.get_boolean (group, "flagged"),
                    important = state.has_key (group, "important") && state.get_boolean (group, "important"),
                    has_attachment = state.has_key (group, "has-attachment")
                        && state.get_boolean (group, "has-attachment"),
                    preview = state.has_key (group, "preview")
                        ? state.get_string (group, "preview")
                        : null,
                    conversation_key = state.has_key (group, "conversation-key")
                        ? state.get_string (group, "conversation-key")
                        : null,
                    local_only = true,
                    msgid_hash = state.get_uint64 (group, "message-id-hash"),
                    folder_name = from_name,
                    folder_full_name = from_full_name,
                    list_address = "",
                    transfer_source_uid = stored_candidate_uid.has_prefix ("local-copy-")
                        ? stored_uid
                        : null,
                    transfer_source_folder = stored_candidate_uid.has_prefix ("local-copy-")
                        ? from_full_name
                        : null,
                };
                var pending = new PendingBodyRekey () {
                    account_key = state.get_string (group, "account"),
                    from = new Folder () {
                        name = from_name,
                        full_name = from_full_name,
                        flags = (uint) state.get_uint64 (group, "from-flags"),
                    },
                    uid = stored_uid,
                    destination = new Folder () {
                        name = destination_name,
                        full_name = destination_full_name,
                        flags = (uint) state.get_uint64 (group, "destination-flags"),
                    },
                    candidate = candidate,
                    resolved_uid = resolved_uid,
                };
                var body_path = pending_body_cache_file (pending);
                if (FileUtils.test (body_path, FileTest.IS_REGULAR))
                    pending.body_path = body_path;
                this.pending_body_rekeys.add (pending);
            } catch (Error e) {
                warning ("Could not restore pending mail synchronization item: %s", e.message);
            }
        }
    }

    private void save_pending_sync_state () {
        var state = new KeyFile ();
        this.persisted_expunges.foreach ((identity, pending) => {
            var group = pending_sync_group ("expunge", identity);
            state.set_string (group, "account", pending.account_key);
            state.set_string (group, "folder", pending.folder_full_name);
            state.set_string (group, "folder-name", pending.folder_name);
            state.set_uint64 (group, "folder-flags", pending.folder_flags);
            state.set_string (group, "uid", pending.uid);
        });
        for (uint i = 0; i < this.pending_body_rekeys.length; i++) {
            var pending = this.pending_body_rekeys[i];
            var identity = "%s\n%s\n%s\n%s".printf (
                pending.account_key,
                pending.from.full_name,
                pending.uid,
                pending.destination.full_name
            );
            var group = pending_sync_group ("body", identity);
            state.set_string (group, "account", pending.account_key);
            state.set_string (group, "from-folder", pending.from.full_name);
            state.set_string (group, "from-name", pending.from.name);
            state.set_uint64 (group, "from-flags", pending.from.flags);
            state.set_string (group, "uid", pending.uid);
            state.set_string (group, "candidate-uid", pending.candidate.uid);
            state.set_string (group, "destination-folder", pending.destination.full_name);
            state.set_string (group, "destination-name", pending.destination.name);
            state.set_uint64 (group, "destination-flags", pending.destination.flags);
            state.set_string (group, "subject", pending.candidate.subject ?? "");
            state.set_string (group, "from", pending.candidate.from ?? "");
            state.set_string (group, "to", pending.candidate.to ?? "");
            state.set_string (group, "cc", pending.candidate.cc ?? "");
            state.set_int64 (group, "date", pending.candidate.date);
            state.set_boolean (group, "outgoing", pending.candidate.outgoing);
            state.set_boolean (group, "seen", pending.candidate.seen);
            state.set_boolean (group, "flagged", pending.candidate.flagged);
            state.set_boolean (group, "important", pending.candidate.important);
            state.set_boolean (group, "has-attachment", pending.candidate.has_attachment);
            state.set_string (group, "preview", pending.candidate.preview ?? "");
            state.set_string (
                group,
                "conversation-key",
                pending.candidate.conversation_key ?? ""
            );
            state.set_uint64 (group, "message-id-hash", pending.candidate.msgid_hash);
            if (pending.resolved_uid != null)
                state.set_string (group, "resolved-uid", pending.resolved_uid);
        }

        var path = pending_sync_state_file ();
        if (this.persisted_expunges.size () == 0 && this.pending_body_rekeys.length == 0) {
            try {
                File.new_for_path (path).delete ();
            } catch (Error e) {
                if (!(e is IOError.NOT_FOUND))
                    debug ("Could not remove completed synchronization state: %s", e.message);
            }
            return;
        }

        try {
            File.new_for_path (Path.get_dirname (path)).make_directory_with_parents ();
        } catch (Error e) {
            if (!(e is IOError.EXISTS)) {
                warning ("Could not create pending synchronization directory: %s", e.message);
                return;
            }
        }
        try {
            state.save_to_file (path);
        } catch (Error e) {
            warning ("Could not save pending mail synchronization state: %s", e.message);
        }
    }

    private void remember_persisted_expunge (FlagFlushJob job) {
        if (!job.expunge || job.uids.length == 0)
            return;
        var key = flag_flush_key (job.account, job.folder);
        this.persisted_expunges.set (key, new PendingExpunge () {
            account_key = job.account.source_uid ?? job.account.uid,
            folder_full_name = job.folder.full_name,
            folder_name = job.folder.name,
            folder_flags = job.folder.flags,
            uid = job.uids[0],
        });
        save_pending_sync_state ();
    }

    private void resume_persisted_expunges (
        Account account,
        GenericArray<Folder> folders
    ) {
        var account_key = account.source_uid ?? account.uid;
        uint resumed = 0;
        this.persisted_expunges.foreach ((key, pending) => {
            if (pending.account_key != account_key || this.flag_flush_latest.contains (key))
                return;

            Folder? folder = null;
            for (uint i = 0; i < folders.length; i++) {
                if (folders[i].full_name == pending.folder_full_name) {
                    folder = folders[i];
                    break;
                }
            }
            if (folder == null) {
                folder = new Folder () {
                    name = pending.folder_name,
                    full_name = pending.folder_full_name,
                    flags = pending.folder_flags,
                };
            }
            var uids = new GenericArray<string> ();
            uids.add (pending.uid);
            var job = new FlagFlushJob () {
                account = account,
                folder = folder,
                uids = uids,
                expunge = true,
            };
            this.flag_flush_latest.set (key, job);
            this.flag_flush_queue.add (job);
            resumed++;
        });
        if (resumed == 0)
            return;
        Utils.sync_log ("restored %u pending expunge jobs".printf (resumed));
        pump_flag_flush.begin ();
    }

    private void enqueue_flag_flush (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        bool expunge = false
    ) {
        var key = flag_flush_key (account, folder);
        var previous = this.flag_flush_latest.get (key);
        var job = new FlagFlushJob () {
            account = account,
            folder = folder,
            uids = uids,
            expunge = expunge || (previous != null && previous.expunge),
        };
        this.flag_flush_latest.set (key, job);
        this.flag_flush_retries.remove (key);
        this.flag_flush_queue.add (job);
        remember_persisted_expunge (job);
        /* Cache-first: local Camel flags are already set. Server push waits for
         * sync-interval / manual refresh (flush_pending_local_changes). */
        Utils.sync_log ("flag flush deferred “%s” %u messages%s".printf (
            folder.name,
            uids.length,
            job.expunge ? " + expunge" : ""
        ));
    }

    /* Failed EXPUNGE jobs stay pending without spinning the current flush.
     * The next periodic/manual/shutdown flush stages one retry. */
    private void stage_flag_flush_retries () {
        var jobs = new GenericArray<FlagFlushJob> ();
        this.flag_flush_retries.foreach ((key, job) => {
            if (this.flag_flush_latest.get (key) == job)
                jobs.add (job);
        });
        this.flag_flush_retries.remove_all ();
        for (uint i = 0; i < jobs.length; i++)
            this.flag_flush_queue.add (jobs[i]);
    }

    private async void pump_flag_flush () {
        if (this.flag_flush_running)
            return;

        this.flag_flush_running = true;
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
        }
    }

    private async void flush_folder_flags (FlagFlushJob job) {
        var key = flag_flush_key (job.account, job.folder);
        Camel.Folder camel_folder;
        try {
            camel_folder = yield open_camel_folder (job.account, job.folder, null);
        } catch (Error e) {
            warning ("Could not push folder flags: %s", e.message);
            if (job.expunge && this.flag_flush_latest.get (key) == job)
                this.flag_flush_retries.set (key, job);
            else if (this.flag_flush_latest.get (key) == job)
                this.flag_flush_latest.remove (key);
            return;
        }

        var t0 = Utils.sync_tick ();
        var logged_pause = false;
        var done = 0u;
        var failed = false;
        while (done < job.uids.length) {
            if (this.flag_flush_latest.get (key) != job)
                return;

            if (this.high_refresh_waiters > 0) {
                if (!logged_pause) {
                    Utils.sync_log ("flag flush paused “%s” for user (%u/%u)".printf (
                        job.folder.name,
                        done,
                        job.uids.length
                    ));
                    logged_pause = true;
                }
                Timeout.add (250, flush_folder_flags.callback);
                yield;
                continue;
            }
            logged_pause = false;

            yield enter_camel (false);
            try {
                /* synchronize_message only downloads bodies. Flag/follow-up/SEEN
                 * uploads go through folder.synchronize → backend save_flags. */
                yield camel_folder.synchronize (job.expunge, Priority.LOW, null);
                done = job.uids.length;
            } catch (Error e) {
                warning ("Could not push folder flags for “%s”: %s", job.folder.name, e.message);
                failed = true;
                done = job.uids.length;
            } finally {
                leave_camel (false);
            }

            Utils.sync_log ("flag flush “%s” %u/%u %s".printf (
                job.folder.name,
                done,
                job.uids.length,
                Utils.sync_ms (t0)
            ));

            Idle.add (flush_folder_flags.callback);
            yield;
        }

        if (this.flag_flush_latest.get (key) != job)
            return;
        apply_camel_counts (job.folder, camel_folder);
        if (failed && job.expunge) {
            this.flag_flush_retries.set (key, job);
            return;
        }
        this.flag_flush_latest.remove (key);
        if (job.expunge && this.persisted_expunges.remove (key))
            save_pending_sync_state ();
        if (!failed)
            this.folder_flags_flushed (job.account, job.folder);
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

    private uint transfer_pending_count (Account account, Folder folder) {
        var key = flag_flush_key (account, folder);
        return this.transfer_pending.contains (key) ? this.transfer_pending.get (key) : 0;
    }

    private async void pump_transfer_flush () {
        if (this.transfer_flush_running)
            return;

        this.transfer_flush_running = true;
        try {
            while (this.transfer_flush_queue.length > 0) {
                var job = this.transfer_flush_queue[0];
                this.transfer_flush_queue.remove_index (0);
                yield flush_folder_transfers (job);
            }
        } finally {
            this.transfer_flush_running = false;
        }
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

        const uint BATCH = 1;
        uint done = 0;
        var t0 = Utils.sync_tick ();
        var logged_pause = false;
        string? transfer_error = null;
        while (done < job.uids.length) {
            if (this.high_refresh_waiters > 0) {
                if (!logged_pause) {
                    Utils.sync_log ("move flush paused “%s” for user (%u/%u)".printf (
                        job.from.name,
                        done,
                        job.uids.length
                    ));
                    logged_pause = true;
                }
                Timeout.add (250, flush_folder_transfers.callback);
                yield;
                continue;
            }
            logged_pause = false;

            var end = done + BATCH;
            if (end > job.uids.length)
                end = job.uids.length;
            var batch = new GenericArray<string> ();
            for (uint i = done; i < end; i++)
                batch.add (job.uids[i]);

            Camel.MimeMessage? captured_body = null;
            if (job.delete_original)
                captured_body = yield capture_local_body (job.account, job.from, batch[0], source_folder);

#if HAVE_CAMEL_3_58
            GenericArray<weak string>? transferred = null;
#else
            GenericArray<string>? transferred = null;
#endif
            try {
                yield enter_camel (false);
                try {
                    yield source_folder.transfer_messages_to (
                        batch,
                        dest_folder,
                        job.delete_original,
                        Priority.LOW,
                        null,
                        out transferred
                    );
                } finally {
                    leave_camel (false);
                }
            } catch (Error e) {
                warning ("Could not move messages: %s", e.message);
                transfer_error = e.message;
                break;
            }

            var pending_changed = false;
            for (uint i = 0; i < batch.length; i++) {
                string? new_uid = null;
                if (transferred != null && i < transferred.length
                    && transferred[i] != null && transferred[i].length > 0)
                    new_uid = transferred[i];
                if (job.delete_original && new_uid != null)
                    rekey_body (job.account, job.from, batch[i], job.destination, new_uid);
                var message_index = done + i;
                if (job.messages != null && message_index < job.messages.length) {
                    var message = job.messages[message_index];
                    if (message != null && new_uid != null && new_uid != message.uid) {
                        if (job.delete_original) {
                            rekey_body (
                                job.account,
                                job.destination,
                                message.uid,
                                job.destination,
                                new_uid
                            );
                        }
                        message.uid = new_uid;
                    }
                    /* Without COPYUID the destination UID is unknown. Retain
                     * the unique local placeholder until header reconciliation
                     * can match the real destination message safely. */
                    if (message != null && new_uid != null)
                        message.local_only = false;
                    if (message != null && new_uid == null) {
                        /* The server completed the move or copy but supplied
                         * no destination UID. Journal the optimistic header
                         * and any offline move body before completion signals
                         * can persist caches that intentionally omit placeholders. */
                        var pending = new PendingBodyRekey () {
                            account_key = job.account.source_uid ?? job.account.uid,
                            from = job.delete_original ? job.destination : job.from,
                            uid = job.delete_original ? message.uid : batch[i],
                            destination = job.destination,
                            candidate = message,
                        };
                        if (captured_body != null)
                            persist_pending_body (pending, captured_body);
                        this.pending_body_rekeys.add (pending);
                        pending_changed = true;
                    }
                }
            }
            if (pending_changed)
                save_pending_sync_state ();

            done = end;
            if (done == job.uids.length || done % 30 == 0) {
                Utils.sync_log ("move flush “%s” → “%s” %u/%u %s".printf (
                    job.from.name,
                    job.destination.name,
                    done,
                    job.uids.length,
                    Utils.sync_ms (t0)
                ));
            }

            Idle.add (flush_folder_transfers.callback);
            yield;
        }

        /* COPY + \Deleted is the fallback when the server lacks UID MOVE.
         * Complete all copies first, then upload/EXPUNGE the source flags once
         * for the whole job instead of once per selected message. */
        if (job.delete_original && done > 0) {
            try {
                yield enter_camel (false);
                try {
                    yield source_folder.synchronize (true, Priority.LOW, null);
                } finally {
                    leave_camel (false);
                }
            } catch (Error e) {
                warning ("Could not expunge moved messages: %s", e.message);
                /* The copies already have destination UIDs. Keep the source
                 * \Deleted flags queued so the next local-change flush retries
                 * only the delete side instead of copying messages again. */
                enqueue_flag_flush (job.account, job.from, job.uids, true);
                if (transfer_error != null)
                    transfer_error = "%s; %s".printf (transfer_error, e.message);
            }
        }

        if (transfer_error != null) {
            finish_transfer_job (job, done, transfer_error);
            return;
        }

        /* A later queued transfer may already be represented optimistically in
         * Folder counts but not in Camel yet. Preserve those deltas until the
         * last job touching each folder has finished. */
        if (transfer_pending_count (job.account, job.from) <= 1)
            apply_camel_counts (job.from, source_folder);
        if (transfer_pending_count (job.account, job.destination) <= 1)
            apply_camel_counts (job.destination, dest_folder);
        bump_transfer_pending (job.account, job.from, -1);
        if (job.from.full_name != job.destination.full_name)
            bump_transfer_pending (job.account, job.destination, -1);
        this.transfer_completed (job.account, job.from, job.destination);
    }

    private void finish_transfer_job (TransferFlushJob job, uint done, string error) {
        bump_transfer_pending (job.account, job.from, -1);
        if (job.from.full_name != job.destination.full_name)
            bump_transfer_pending (job.account, job.destination, -1);

        var remaining = new GenericArray<string> ();
        for (uint i = done; i < job.uids.length; i++)
            remaining.add (job.uids[i]);
        GenericArray<Message>? remaining_messages = null;
        if (job.messages != null) {
            remaining_messages = new GenericArray<Message> ();
            for (uint i = done; i < job.messages.length; i++)
                remaining_messages.add (job.messages[i]);
        }
        GenericArray<TransferCountChange>? remaining_count_changes = null;
        if (job.count_changes != null) {
            remaining_count_changes = new GenericArray<TransferCountChange> ();
            for (uint i = done; i < job.count_changes.length; i++)
                remaining_count_changes.add (job.count_changes[i]);
        }
        this.transfer_failed (
            job.account,
            job.from,
            job.destination,
            remaining,
            remaining_messages,
            remaining_count_changes,
            error
        );
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

    private async Camel.MimeMessage? capture_local_body (
        Account account,
        Folder folder,
        string uid,
        Camel.Folder camel_folder
    ) {
        var mime = message_from_local_cache (camel_folder, uid);
        if (mime != null && !this.body_cache.contains (body_key (account, folder, uid)))
            this.body_cache.set (body_key (account, folder, uid), MessageContent.from_mime (uid, mime));
        return mime;
    }

    private static bool is_missing_on_server (Error error) {
        var text = error.message ?? "";
        return error is IOError.NOT_FOUND
            || text.contains ("ErrorItemNotFound")
            || text.contains ("not found in the store");
    }

    private async Camel.Folder open_camel_folder (
        Account account,
        Folder folder,
        Cancellable? cancellable,
        bool online = true
    ) throws Error {
        if (folder.is_virtual_view) {
            throw new IOError.NOT_SUPPORTED (
                _("“%s” is a local view, not a mail folder.").printf (folder.name)
            );
        }

        var store = yield open_store (account, cancellable, online);
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
        var account_key = account.source_uid ?? account.uid;
        var changed = false;
        for (int i = (int) this.pending_body_rekeys.length - 1; i >= 0; i--) {
            var pending = this.pending_body_rekeys[i];
            if (pending.account_key != account_key
                || pending.destination.full_name != folder.full_name
                || pending.resolved_uid != uid)
                continue;
            discard_pending_body (pending);
            this.pending_body_rekeys.remove_index (i);
            changed = true;
        }
        if (changed)
            save_pending_sync_state ();
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
        var account_key = account.source_uid ?? account.uid;
        for (int i = (int) this.pending_body_rekeys.length - 1; i >= 0; i--) {
            if (this.pending_body_rekeys[i].account_key == account_key) {
                discard_pending_body (this.pending_body_rekeys[i]);
                this.pending_body_rekeys.remove_index (i);
            }
        }
        var expunge_keys = new GenericArray<string> ();
        this.persisted_expunges.foreach ((key, pending) => {
            if (pending.account_key == account_key)
                expunge_keys.add (key);
        });
        for (uint i = 0; i < expunge_keys.length; i++)
            this.persisted_expunges.remove (expunge_keys[i]);
        save_pending_sync_state ();
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
        bool is_forward = false
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
            is_forward
        );

        var transport = yield open_transport (account, cancellable);
        bool saved = false;
        var t0 = Utils.sync_tick ();
        Utils.sync_log ("send start from=%s to=%s".printf (identity.address, to));
        yield enter_camel (true);
        try {
            yield transport.send_to (mime, from_addr, recipients, Priority.DEFAULT, cancellable, out saved);
        } finally {
            leave_camel (true);
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
        Cancellable? cancellable = null
    ) throws Error {
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
            is_forward
        );
        Folder? drafts;
        var uid = yield save_to_folder (account, FolderKind.DRAFTS, mime, cancellable, out drafts);
        if (drafts == null)
            return null;

        if (uid == null || uid.length == 0)
            uid = "local-draft-%lld".printf (new DateTime.now_utc ().to_unix ());
        var content = MessageContent.from_mime (uid, mime);
        this.body_cache.set (body_key (account, drafts, uid), content);
        var draft = message_from_mime (uid, mime, drafts, content.plain_text ?? body);
        draft_saved (account, draft);
        return draft;
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
        bool is_forward = false
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
        var has_html = html != null && html.strip ().length > 0;
        var has_files = attachments != null && attachments.length > 0;

        if (!has_files)
            return build_alternative (plain, html);

        var mixed = new Camel.Multipart ();
        mixed.set_mime_type ("multipart/mixed");
        mixed.set_boundary (null);

        if (has_html) {
            var body_part = new Camel.MimePart ();
            ((Camel.Medium) body_part).set_content (build_alternative (plain, html));
            mixed.add_part (body_part);
        } else {
            var text_part = new Camel.MimePart ();
            text_part.set_content (plain.data, "text/plain; charset=UTF-8");
            text_part.set_encoding (Camel.TransferEncoding.ENCODING_8BIT);
            mixed.add_part (text_part);
        }

        for (uint i = 0; i < attachments.length; i++) {
            var attachment = attachments[i];
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
                    _("“%s” is not a valid email address.").printf (addr.length > 0 ? addr : _("recipient"))
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

public class Mail.TransferCountChange : Object {
    public bool source_total_decremented;
    public bool source_unread_decremented;
    public bool destination_total_incremented;
    public bool destination_unread_incremented;
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
