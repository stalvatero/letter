/**
 * Seam for account discovery (Platform Phase 0).
 *
 * UI and AccountStore sit on this; GOA+EDS is one adapter. A future
 * Letter Identity source plugs in beside it without rewriting the shell.
 */
public interface Mail.AccountSource : Object {
    public abstract string id { get; }
    public abstract string? error_message { get; }
    public abstract uint calendar_count { get; }
    public abstract uint contact_count { get; }

    /**
     * EDS registry when this source provides one (Calendar/Contacts still
     * bind here until they get their own seams). Null for Identity-only.
     */
    public abstract E.SourceRegistry? registry { get; }

    public signal void changed ();

    public abstract async void load ();

    /**
     * Accounts that create list rows. Today: GOA objects.
     */
    public abstract GenericArray<Account> primary_accounts ();

    /**
     * Accounts that only enrich matching rows (source_uid, backend, …).
     * Today: EDS mail sources. Does not add unmatched rows — same as
     * the pre-seam AccountStore merge.
     */
    public abstract GenericArray<Account> enrichment_accounts ();
}
