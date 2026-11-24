/**
 * Letter-owned AccountSource (Phase 1 Identity).
 * Lists on-disk identity accounts. GOA remains a sibling source.
 */
public class Mail.LetterIdentityAccountSource : Object, AccountSource {
    public string id {
        get {
            return "letter-identity";
        }
    }

    public string? error_message {
        get {
            return this._error_message;
        }
    }

    public uint calendar_count {
        get {
            return 0;
        }
    }

    public uint contact_count {
        get {
            return 0;
        }
    }

    public E.SourceRegistry? registry {
        get {
            return null;
        }
    }

    private string? _error_message;
    private IdentityCatalog catalog = new IdentityCatalog ();
    private bool loaded = false;

    public async void load () {
        this._error_message = null;
        try {
            this.catalog = IdentityCatalog.load ();
            this.loaded = true;
        } catch (Error e) {
            warning ("Letter Identity catalog: %s", e.message);
            this._error_message = e.message;
            this.catalog = new IdentityCatalog ();
            this.loaded = true;
        }
        /* No yield needed; keep async for AccountSource. */
        Idle.add (load.callback);
        yield;
    }

    public GenericArray<Account> primary_accounts () {
        var list = new GenericArray<Account> ();
        if (!this.loaded)
            return list;
        for (uint i = 0; i < this.catalog.accounts.length; i++) {
            var id_acc = this.catalog.accounts[i];
            if (!id_acc.enabled)
                continue;
            list.add (id_acc.to_account ());
        }
        return list;
    }

    public GenericArray<Account> enrichment_accounts () {
        return new GenericArray<Account> ();
    }

    /** Reload from disk (after CLI / future wizard writes). */
    public void reload_from_disk () {
        try {
            this.catalog = IdentityCatalog.load ();
            this._error_message = null;
        } catch (Error e) {
            this._error_message = e.message;
        }
        changed ();
    }
}
