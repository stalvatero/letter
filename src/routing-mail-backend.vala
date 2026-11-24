/**
 * Routes mail I/O by account: letter-imap → ImapMailBackend, else Camel MailSession.
 * Lets Identity accounts use the Letter engine while GOA/EDS accounts keep Camel
 * in the same session (no LETTER_SKIP_GOA required for Identity mail).
 */
public class Mail.RoutingMailBackend : Object, MailBackend {
    private MailSession? camel;
    private ImapMailBackend imap;
    private MailBackend? last_list_backend;

    public bool header_sync_busy {
        get {
            return this.imap.header_sync_busy
                || (this.camel != null && this.camel.header_sync_busy);
        }
    }

    public bool last_list_refresh_incomplete {
        get {
            return this.last_list_backend != null
                && this.last_list_backend.last_list_refresh_incomplete;
        }
    }

    public bool last_list_refresh_failed {
        get {
            return this.last_list_backend != null
                && this.last_list_backend.last_list_refresh_failed;
        }
    }

    public bool last_list_refresh_completed {
        get {
            return this.last_list_backend != null
                && this.last_list_backend.last_list_refresh_completed;
        }
    }

    public bool last_list_refresh_authoritative {
        get {
            return this.last_list_backend != null
                && this.last_list_backend.last_list_refresh_authoritative;
        }
    }

    public RoutingMailBackend (E.SourceRegistry registry) {
        this.camel = new MailSession (registry);
        this.imap = new ImapMailBackend ();
        wire_signals (this.camel);
        wire_signals (this.imap);
    }

    private void wire_signals (MailBackend backend) {
        backend.folder_changed.connect ((a, f) => {
            folder_changed (a, f);
        });
        backend.send_starting.connect (() => {
            send_starting ();
        });
        backend.send_finished.connect (() => {
            send_finished ();
        });
        backend.message_sent.connect ((account, sent) => {
            message_sent (account, sent);
        });
        backend.draft_saved.connect ((account, draft, replaced) => {
            draft_saved (account, draft, replaced);
        });
        backend.draft_removed.connect ((account, folder, uid) => {
            draft_removed (account, folder, uid);
        });
        backend.transfer_failed.connect ((account, from, uids, error) => {
            transfer_failed (account, from, uids, error);
        });
    }

    private MailBackend engine (Account account) {
        if (account.backend_name == "letter-imap")
            return this.imap;
        if (this.camel != null)
            return this.camel;
        return this.imap;
    }

    public async GenericArray<Folder> list_folders (
        Account account,
        Cancellable? cancellable = null,
        bool refresh = true
    ) throws Error {
        return yield engine (account).list_folders (account, cancellable, refresh);
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
        var backend = engine (account);
        this.last_list_backend = backend;
        return yield backend.list_messages (
            account,
            folder,
            refresh,
            cancellable,
            watch,
            previous,
            high,
            refresh_timeout_seconds
        );
    }

    public async void follow_folder (Account account, Folder folder) throws Error {
        yield engine (account).follow_folder (account, folder);
    }

    public async GenericArray<Message> search_folder_local (
        Account account,
        Folder folder,
        SearchQuery query,
        bool include_body = true,
        uint limit = 400
    ) throws Error {
        return yield engine (account).search_folder_local (
            account,
            folder,
            query,
            include_body,
            limit
        );
    }

    public async uint index_more_cached_bodies (
        Account account,
        Folder folder,
        uint max_new = 500,
        Cancellable? cancellable = null
    ) throws Error {
        return yield engine (account).index_more_cached_bodies (
            account,
            folder,
            max_new,
            cancellable
        );
    }

    public async int local_uid_count (
        Account account,
        Folder folder,
        Cancellable? cancellable = null
    ) throws Error {
        return yield engine (account).local_uid_count (account, folder, cancellable);
    }

    public bool peek_folder_remote_counts (
        Account account,
        Folder folder,
        out int total,
        out int unread
    ) {
        return engine (account).peek_folder_remote_counts (account, folder, out total, out unread);
    }

    public void unwatch_all_folders () {
        this.imap.unwatch_all_folders ();
        this.camel?.unwatch_all_folders ();
    }

    public GenericArray<string> apply_live_flags (
        Account account,
        Folder folder,
        GenericArray<Message> messages
    ) {
        return engine (account).apply_live_flags (account, folder, messages);
    }

    public uint append_live_headers (
        Account account,
        Folder folder,
        GenericArray<Message> messages
    ) {
        return engine (account).append_live_headers (account, folder, messages);
    }

    public MessageContent? peek_body (Account account, Folder folder, string uid) {
        return engine (account).peek_body (account, folder, uid);
    }

    public async MessageContent? try_load_body_from_disk (
        Account account,
        Folder folder,
        string uid,
        Cancellable? cancellable = null
    ) throws Error {
        return yield engine (account).try_load_body_from_disk (account, folder, uid, cancellable);
    }

    public void rekey_body (
        Account account,
        Folder from,
        string old_uid,
        Folder dest,
        string new_uid
    ) {
        engine (account).rekey_body (account, from, old_uid, dest, new_uid);
    }

    public async MessageContent load_message (
        Account account,
        Folder folder,
        string uid,
        Cancellable? cancellable = null
    ) throws Error {
        return yield engine (account).load_message (account, folder, uid, cancellable);
    }

    public async void export_message_eml (
        Account account,
        Folder folder,
        string uid,
        File dest,
        Cancellable? cancellable = null
    ) throws Error {
        yield engine (account).export_message_eml (account, folder, uid, dest, cancellable);
    }

    public void queue_mark_seen (Account account, Folder folder, string uid) {
        engine (account).queue_mark_seen (account, folder, uid);
    }

    public async void set_message_seen (
        Account account,
        Folder folder,
        string uid,
        bool seen,
        Cancellable? cancellable = null
    ) throws Error {
        yield engine (account).set_message_seen (account, folder, uid, seen, cancellable);
    }

    public async uint prefetch_recent (
        Account account,
        Folder folder,
        GenericArray<Message> listed,
        int days,
        Cancellable? cancellable = null,
        int max_index = -1
    ) throws Error {
        return yield engine (account).prefetch_recent (
            account,
            folder,
            listed,
            days,
            cancellable,
            max_index
        );
    }

    public void reset_prefetch_progress (Account? account = null) {
        this.imap.reset_prefetch_progress (account);
        this.camel?.reset_prefetch_progress (account);
    }

    public void flush_prefetch_progress () {
        this.imap.flush_prefetch_progress ();
        this.camel?.flush_prefetch_progress ();
    }

    public void release_transient_memory () {
        this.imap.release_transient_memory ();
        this.camel?.release_transient_memory ();
    }

    public void relieve_memory_pressure () {
        this.imap.relieve_memory_pressure ();
        this.camel?.relieve_memory_pressure ();
    }

    public async string copy_message (
        Account account,
        Folder from,
        string uid,
        Folder destination,
        Cancellable? cancellable = null
    ) throws Error {
        return yield engine (account).copy_message (account, from, uid, destination, cancellable);
    }

    public void enqueue_move_messages (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        GenericArray<Message>? messages
    ) {
        engine (account).enqueue_move_messages (account, from, destination, uids, messages);
    }

    public void cancel_queued_moves (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        bool delete_original = true
    ) {
        engine (account).cancel_queued_moves (account, from, destination, uids, delete_original);
    }

    public void enqueue_copy_messages (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        GenericArray<Message>? messages
    ) {
        engine (account).enqueue_copy_messages (account, from, destination, uids, messages);
    }

    public void flush_pending_local_changes () {
        this.imap.flush_pending_local_changes ();
        this.camel?.flush_pending_local_changes ();
    }

    public bool has_blocking_local_flushes () {
        return this.imap.has_blocking_local_flushes ()
            || (this.camel != null && this.camel.has_blocking_local_flushes ());
    }

    public void unpark_heavy_transfers () {
        this.imap.unpark_heavy_transfers ();
        this.camel?.unpark_heavy_transfers ();
    }

    public async bool flush_pending_local_changes_with_timeout (uint seconds) {
        var imap_ok = yield this.imap.flush_pending_local_changes_with_timeout (seconds);
        var camel_ok = true;
        if (this.camel != null)
            camel_ok = yield this.camel.flush_pending_local_changes_with_timeout (seconds);
        return imap_ok && camel_ok;
    }

    public void persist_mutation_registry_now () {
        this.imap.persist_mutation_registry_now ();
        this.camel?.persist_mutation_registry_now ();
    }

    public uint load_mutation_registry () {
        uint n = this.imap.load_mutation_registry ();
        if (this.camel != null)
            n += this.camel.load_mutation_registry ();
        return n;
    }

    public void foreach_queued_move_hide (QueuedMoveHideFunc func) {
        this.imap.foreach_queued_move_hide (func);
        this.camel?.foreach_queued_move_hide (func);
    }

    public bool has_pending_local_flushes () {
        return this.imap.has_pending_local_flushes ()
            || (this.camel != null && this.camel.has_pending_local_flushes ());
    }

    public async void flush_pending_local_changes_async () {
        yield this.imap.flush_pending_local_changes_async ();
        if (this.camel != null)
            yield this.camel.flush_pending_local_changes_async ();
    }

    public async void delete_message (
        Account account,
        Folder folder,
        string uid,
        Folder? trash,
        Cancellable? cancellable = null
    ) throws Error {
        yield engine (account).delete_message (account, folder, uid, trash, cancellable);
    }

    public async void delete_message_local (
        Account account,
        Folder folder,
        string uid
    ) throws Error {
        yield engine (account).delete_message_local (account, folder, uid);
    }

    public async void delete_uids (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        Folder? trash
    ) throws Error {
        yield engine (account).delete_uids (account, folder, uids, trash);
    }

    public async void empty_folder (Account account, Folder folder) throws Error {
        yield engine (account).empty_folder (account, folder);
    }

    public async void set_folder_seen (Account account, Folder folder, bool seen) throws Error {
        yield engine (account).set_folder_seen (account, folder, seen);
    }

    public async void set_uids_seen (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        bool seen
    ) throws Error {
        yield engine (account).set_uids_seen (account, folder, uids, seen);
    }

    public async void set_uids_flagged (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        bool flagged
    ) throws Error {
        yield engine (account).set_uids_flagged (account, folder, uids, flagged);
    }

    public bool folder_has_pending_flags (Account account, Folder folder) {
        return engine (account).folder_has_pending_flags (account, folder);
    }

    public async void create_mailbox_folder (
        Account account,
        Folder parent,
        string name
    ) throws Error {
        yield engine (account).create_mailbox_folder (account, parent, name);
    }

    public async void rename_mailbox_folder (
        Account account,
        Folder folder,
        string new_full_name
    ) throws Error {
        yield engine (account).rename_mailbox_folder (account, folder, new_full_name);
    }

    public async void delete_mailbox_folder (
        Account account,
        Folder folder
    ) throws Error {
        yield engine (account).delete_mailbox_folder (account, folder);
    }

    public void retire_moved_uid (Account account, Folder folder, string uid) {
        engine (account).retire_moved_uid (account, folder, uid);
    }

    public void unretire_moved_uid (Account account, Folder folder, string uid) {
        engine (account).unretire_moved_uid (account, folder, uid);
    }

    public GenericArray<Message> without_retired_moves (
        Account account,
        Folder folder,
        GenericArray<Message> messages
    ) {
        return engine (account).without_retired_moves (account, folder, messages);
    }

    public Identity? get_identity (Account account) {
        return engine (account).get_identity (account);
    }

    public void ensure_can_send (
        Account account,
        string to,
        string? cc,
        string? bcc
    ) throws Error {
        engine (account).ensure_can_send (account, to, cc, bcc);
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
        yield engine (account).send_message (
            account,
            to,
            cc,
            subject,
            body,
            html,
            bcc,
            attachments,
            reply_of,
            cancellable,
            is_forward,
            high_priority
        );
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
        return yield engine (account).save_draft (
            account,
            to,
            cc,
            subject,
            body,
            html,
            bcc,
            attachments,
            reply_of,
            is_forward,
            high_priority,
            cancellable,
            replace_uid,
            replace_folder,
            out drafts_folder
        );
    }

    public async void reset_account_storage (Account account) throws Error {
        yield engine (account).reset_account_storage (account);
    }
}
