/**
 * Product mail-engine seam (Platform Phase 0).
 *
 * UI talks to MailBackend. Today the only implementation is Camel-backed
 * MailSession. A future Letter Engine backend plugs in without rewriting
 * the shell. Cache-first mutation policy applies to this façade — see
 * cache-first-sync-mutations.mdc — not as Camel APIs.
 *
 * Disk-path helpers and tuning constants still live as MailSession statics
 * until extracted; instance mail I/O goes through this interface.
 */
public delegate void Mail.QueuedMoveHideFunc (Account account, Folder from, string uid);

public interface Mail.MailBackend : Object {
    public abstract bool header_sync_busy { get; }
    public abstract bool last_list_refresh_incomplete { get; }
    public abstract bool last_list_refresh_failed { get; }
    public abstract bool last_list_refresh_completed { get; }
    /* Finished walk with Camel already near Letter — safe catastrophic shrink. */
    public abstract bool last_list_refresh_authoritative { get; }

    public signal void folder_changed (string account_key, string folder_name);
    public signal void send_starting ();
    public signal void send_finished ();
    public signal void message_sent (Account account, Message? sent);
    public signal void draft_saved (Account account, Message? draft, string? replaced_uid);
    public signal void draft_removed (Account account, Folder folder, string uid);
    public signal void transfer_failed (Account account, Folder from, GenericArray<string> uids, string error);

    public abstract async GenericArray<Folder> list_folders (
        Account account,
        Cancellable? cancellable = null,
        bool refresh = true
    ) throws Error;

    public abstract async GenericArray<Message> list_messages (
        Account account,
        Folder folder,
        bool refresh,
        Cancellable? cancellable = null,
        bool watch = false,
        GenericArray<Message>? previous = null,
        bool high = false,
        uint refresh_timeout_seconds = 0
    ) throws Error;

    public abstract async void follow_folder (Account account, Folder folder) throws Error;

    public abstract async GenericArray<Message> search_folder_local (
        Account account,
        Folder folder,
        SearchQuery query,
        bool include_body = true,
        uint limit = 400
    ) throws Error;

    public abstract async uint index_more_cached_bodies (
        Account account,
        Folder folder,
        uint max_new = 500,
        Cancellable? cancellable = null
    ) throws Error;

    public abstract async int local_uid_count (
        Account account,
        Folder folder,
        Cancellable? cancellable = null
    ) throws Error;

    /**
     * Server folder totals when known without equating them to the local
     * header list length (IMAP STATUS / EXISTS). Return false if unknown.
     */
    public abstract bool peek_folder_remote_counts (
        Account account,
        Folder folder,
        out int total,
        out int unread
    );

    public abstract void unwatch_all_folders ();

    public abstract GenericArray<string> apply_live_flags (
        Account account,
        Folder folder,
        GenericArray<Message> messages
    );

    public abstract uint append_live_headers (
        Account account,
        Folder folder,
        GenericArray<Message> messages
    );

    public abstract MessageContent? peek_body (Account account, Folder folder, string uid);

    public abstract async MessageContent? try_load_body_from_disk (
        Account account,
        Folder folder,
        string uid,
        Cancellable? cancellable = null
    ) throws Error;

    public abstract void rekey_body (
        Account account,
        Folder from,
        string old_uid,
        Folder dest,
        string new_uid
    );

    public abstract async MessageContent load_message (
        Account account,
        Folder folder,
        string uid,
        Cancellable? cancellable = null
    ) throws Error;

    public abstract async void export_message_eml (
        Account account,
        Folder folder,
        string uid,
        File dest,
        Cancellable? cancellable = null
    ) throws Error;

    public abstract void queue_mark_seen (Account account, Folder folder, string uid);

    public abstract async void set_message_seen (
        Account account,
        Folder folder,
        string uid,
        bool seen,
        Cancellable? cancellable = null
    ) throws Error;

    public abstract async uint prefetch_recent (
        Account account,
        Folder folder,
        GenericArray<Message> listed,
        int days,
        Cancellable? cancellable = null,
        int max_index = -1
    ) throws Error;

    public abstract void reset_prefetch_progress (Account? account = null);
    public abstract void flush_prefetch_progress ();
    public abstract void release_transient_memory ();
    public abstract void relieve_memory_pressure ();

    public abstract async string copy_message (
        Account account,
        Folder from,
        string uid,
        Folder destination,
        Cancellable? cancellable = null
    ) throws Error;

    public abstract void enqueue_move_messages (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        GenericArray<Message>? messages
    );

    public abstract void cancel_queued_moves (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        bool delete_original = true
    );

    public abstract void enqueue_copy_messages (
        Account account,
        Folder from,
        Folder destination,
        GenericArray<string> uids,
        GenericArray<Message>? messages
    );

    public abstract void flush_pending_local_changes ();
    public abstract bool has_blocking_local_flushes ();
    public abstract void unpark_heavy_transfers ();
    public abstract async bool flush_pending_local_changes_with_timeout (uint seconds);
    public abstract void persist_mutation_registry_now ();
    public abstract uint load_mutation_registry ();
    public abstract void foreach_queued_move_hide (QueuedMoveHideFunc func);
    public abstract bool has_pending_local_flushes ();
    public abstract async void flush_pending_local_changes_async ();

    public abstract async void delete_message (
        Account account,
        Folder folder,
        string uid,
        Folder? trash,
        Cancellable? cancellable = null
    ) throws Error;

    public abstract async void delete_message_local (
        Account account,
        Folder folder,
        string uid
    ) throws Error;

    public abstract async void delete_uids (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        Folder? trash
    ) throws Error;

    public abstract async void empty_folder (Account account, Folder folder) throws Error;

    public abstract async void set_folder_seen (Account account, Folder folder, bool seen) throws Error;

    public abstract async void set_uids_seen (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        bool seen
    ) throws Error;

    public abstract async void set_uids_flagged (
        Account account,
        Folder folder,
        GenericArray<string> uids,
        bool flagged
    ) throws Error;

    public abstract bool folder_has_pending_flags (Account account, Folder folder);

    public abstract async void create_mailbox_folder (
        Account account,
        Folder parent,
        string name
    ) throws Error;

    public abstract async void rename_mailbox_folder (
        Account account,
        Folder folder,
        string new_full_name
    ) throws Error;

    public abstract async void delete_mailbox_folder (
        Account account,
        Folder folder
    ) throws Error;

    public abstract void retire_moved_uid (Account account, Folder folder, string uid);
    public abstract void unretire_moved_uid (Account account, Folder folder, string uid);

    public abstract GenericArray<Message> without_retired_moves (
        Account account,
        Folder folder,
        GenericArray<Message> messages
    );

    public abstract Identity? get_identity (Account account);

    public abstract void ensure_can_send (
        Account account,
        string to,
        string? cc,
        string? bcc
    ) throws Error;

    public abstract async void send_message (
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
    ) throws Error;

    public abstract async Message? save_draft (
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
    ) throws Error;

    public abstract async void reset_account_storage (Account account) throws Error;

    /**
     * Construct the default (Camel) backend. Golden-path Engine will add
     * another implementation; keep call sites on this factory.
     */
    public static MailBackend open (E.SourceRegistry registry) {
        return new MailSession (registry);
    }

    /** Letter IMAP engine (Phase 2) — no Camel / EDS. */
    public static MailBackend open_imap () {
        return new ImapMailBackend ();
    }

    /**
     * Pick backend(s) for this session: Identity letter-imap always gets
     * ImapMailBackend; GOA/EDS accounts keep Camel when a registry exists.
     */
    public static MailBackend open_for_store (E.SourceRegistry? registry, bool has_letter_imap) {
        if (registry != null && has_letter_imap)
            return new RoutingMailBackend (registry);
        if (registry != null)
            return new MailSession (registry);
        return new ImapMailBackend ();
    }
}
