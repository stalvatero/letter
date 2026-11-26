/**
 * In-place Microsoft Graph re-consent UI — same Identity UUID, library untouched.
 */
public class Mail.IdentityMicrosoftReconsent : Object {
    /**
     * One dialog for every Identity Microsoft account that still needs the
     * current Graph scopes; Accedi then runs browser consent per account.
     * Returns how many accounts were successfully updated.
     */
    public static async uint prompt_and_reconsent_all (
        Gtk.Window? parent,
        GenericArray<IdentityAccount> accounts
    ) {
        if (accounts.length == 0)
            return 0;

        var emails = new StringBuilder ();
        var missing_ids = new GenericArray<string> ();
        var seen_scope = new HashTable<string, bool> (str_hash, str_equal);
        for (uint i = 0; i < accounts.length; i++) {
            var acc = accounts[i];
            if (i > 0)
                emails.append ("\n");
            emails.append ("• ");
            emails.append (acc.email ?? acc.id);
            var missing_for_acc = IdentityOAuth.graph_missing_upgrade_scopes (acc);
            for (uint s = 0; s < missing_for_acc.length; s++) {
                var scope_id = missing_for_acc[s];
                if (seen_scope.contains (scope_id))
                    continue;
                seen_scope.set (scope_id, true);
                missing_ids.add (scope_id);
            }
        }
        if (missing_ids.length == 0) {
            foreach (var scope_id in IdentityOAuth.microsoft_graph_upgrade_delegated_scopes ())
                missing_ids.add (scope_id);
        }

        var perms = new StringBuilder ();
        for (uint i = 0; i < missing_ids.length; i++) {
            perms.append ("• ");
            perms.append (IdentityOAuth.human_label_for_graph_scope (missing_ids[i]));
            perms.append ("\n");
        }

        var body = _("Letter has introduced features that need an update to the Microsoft permissions already granted. Specifically:\n\n%s\nYou need to sign in again to refresh these permissions for:\n\n%s\n\nYour mail library stays protected on this device; after sign-in you can keep using Letter with the new features. Choose Sign in now, or Later — if you wait, the new features stay unavailable until you sign in again, and this dialog will appear the next time you start Letter.")
            .printf (perms.str, emails.str);

        var dialog = new Adw.AlertDialog (
            _("Microsoft permissions update"),
            body
        );
        dialog.add_response ("later", _("Later"));
        dialog.add_response ("signin", _("Sign in"));
        dialog.set_response_appearance ("signin", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "signin";
        dialog.close_response = "later";

        var response = yield dialog.choose (parent, null);
        if (response != "signin")
            return 0;

        uint updated = 0;
        for (uint i = 0; i < accounts.length; i++) {
            var acc = accounts[i];
            var wait = new Adw.AlertDialog (
                _("Sign in with Microsoft"),
                _("Complete sign-in in your browser for “%s”. Letter is waiting for the redirect…")
                    .printf (acc.email ?? "")
            );
            wait.add_response ("cancel", _("Cancel"));
            wait.default_response = "cancel";
            var cancellable = new Cancellable ();
            wait.response.connect (() => cancellable.cancel ());
            wait.present (parent);

            try {
                yield IdentityOAuth.reconsent_microsoft_graph_inplace (acc, cancellable);
                wait.force_close ();
                updated++;
            } catch (Error e) {
                wait.force_close ();
                if (e is IOError.CANCELLED || e is IdentityOAuthError.CANCELLED)
                    break;
                var err = new Adw.AlertDialog (_("Could not update permissions"), e.message);
                err.add_response ("ok", _("OK"));
                err.present (parent);
                warning ("Microsoft Graph re-consent failed for %s: %s", acc.email, e.message);
                break;
            }
        }
        return updated;
    }
}
