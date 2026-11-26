/**
 * Standalone Microsoft Graph + OAuth PKCE spike — no Camel / evolution-ews.
 *
 *   LETTER_MS_CLIENT_ID='…' ./letter-graph-spike
 *
 * Or skip browser login with an existing token:
 *   LETTER_MS_ACCESS_TOKEN='…' ./letter-graph-spike
 *
 * Optional: LETTER_MS_TENANT=common|consumers|organizations|<tenant-id>
 * Optional: LETTER_MS_DEVICE_CODE=1  → device-code flow (no localhost; Flatpak-friendly)
 */
private static int main (string[] args) {
    var loop = new MainLoop ();
    int status = 1;
    run.begin ((obj, res) => {
        try {
            status = run.end (res);
        } catch (GLib.Error e) {
            stderr.printf ("Graph check failed: %s\n", e.message);
            status = 1;
        }
        loop.quit ();
    });
    loop.run ();
    return status;
}

private async int run () throws GLib.Error {
    var access = Environment.get_variable ("LETTER_MS_ACCESS_TOKEN");
    if (access == null || access.length == 0) {
        var client_id = Environment.get_variable ("LETTER_MS_CLIENT_ID");
        if (client_id == null || client_id.length == 0) {
            stderr.printf (
                "Set LETTER_MS_CLIENT_ID (Azure public app) or LETTER_MS_ACCESS_TOKEN.\n" +
                "See .cursor/PLATFORM-GRAPH-SPIKE.md for Azure app registration.\n"
            );
            return 2;
        }
        var tenant = Environment.get_variable ("LETTER_MS_TENANT") ?? "common";
        var device = Environment.get_variable ("LETTER_MS_DEVICE_CODE");
        var use_device = device != null && (device == "1" || device.down () == "true" || device.down () == "yes");
        var oauth = new LetterGraph.OAuthPkce (client_id, tenant);
        LetterGraph.TokenSet tokens;
        if (use_device) {
            stdout.printf ("Starting OAuth device code (tenant=%s)…\n", tenant);
            tokens = yield oauth.authorize_device_code ();
        } else {
            stdout.printf ("Starting OAuth PKCE loopback (tenant=%s)…\n", tenant);
            tokens = yield oauth.authorize ();
        }
        access = tokens.access_token;
        stdout.printf (
            "Token ok (expires_in=%lld, refresh=%s)\n",
            tokens.expires_in,
            tokens.refresh_token != null ? "yes" : "no"
        );
    } else {
        stdout.printf ("Using LETTER_MS_ACCESS_TOKEN (skip OAuth)\n");
    }

    var graph = new LetterGraph.Client (access);
    var me = yield graph.get_me_display ();
    stdout.printf ("Graph /me → %s\n", me);

    var folders = yield graph.list_mail_folders ();
    stdout.printf ("mailFolders → %u\n", folders.length);
    var show = uint.min (folders.length, 20);
    for (uint i = 0; i < show; i++) {
        stdout.printf (
            "  %s (%lld)\n",
            folders[i].display_name,
            folders[i].total_item_count
        );
    }

    var headers = yield graph.list_inbox_headers (5);
    stdout.printf ("Inbox headers → %u\n", headers.length);
    for (uint i = 0; i < headers.length; i++) {
        var h = headers[i];
        stdout.printf (
            "  %s\n    From: %s\n    Date: %s\n",
            h.subject ?? "(no subject)",
            h.from ?? "(unknown)",
            h.received ?? "(unknown)"
        );
    }

    if (headers.length == 0) {
        stdout.printf ("Inbox empty; done.\n");
        stdout.printf ("OK — Graph check succeeded without Camel/evolution-ews.\n");
        return 0;
    }

    var body = yield graph.fetch_body_preview (headers[0].id);
    stdout.printf ("FETCH body (newest) → %u bytes\n", body.length);
    var preview = body.length > 400 ? body.substring (0, 400) + "\n…" : body;
    stdout.printf ("---- body preview ----\n%s\n----------------------\n", preview);

    stdout.printf ("OK — Graph check succeeded without Camel/evolution-ews.\n");
    return 0;
}
