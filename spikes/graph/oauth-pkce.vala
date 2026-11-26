/**
 * Microsoft identity platform authorization-code + PKCE.
 * Localhost redirect — no client secret (public client).
 */
public errordomain LetterGraph.OAuthError {
    CANCELLED,
    HTTP,
    TOKEN,
    STATE
}

public class LetterGraph.TokenSet : Object {
    public string access_token { get; set; }
    public string? refresh_token { get; set; }
    public string? token_type { get; set; }
    public int64 expires_in { get; set; }
}

public class LetterGraph.OAuthPkce : Object {
    public string client_id { get; private set; }
    public string tenant { get; private set; }
    public string scope { get; private set; }

    private Soup.Session session;

    public OAuthPkce (string client_id, string tenant = "common") {
        this.client_id = client_id;
        this.tenant = tenant;
        this.scope = "offline_access User.Read Mail.Read";
        this.session = new Soup.Session ();
    }

    public async TokenSet authorize (Cancellable? cancellable = null) throws GLib.Error {
        var verifier = Pkce.create_verifier ();
        var challenge = Pkce.challenge_s256 (verifier);
        var state = Pkce.create_state ();

        /* Vala binds soup_server_new as (prop, …); null ends the list. */
        var server = new Soup.Server (null);
        string? auth_code = null;
        string? returned_state = null;
        string? oauth_error = null;
        var loop = new MainLoop ();

        server.add_handler ("/letter-oauth", (serv, msg, path, query) => {
            if (query != null) {
                auth_code = query.lookup ("code");
                returned_state = query.lookup ("state");
                oauth_error = query.lookup ("error");
            }

            var body = "<html><body><h1>Letter E-mail Client</h1><p>You can close this tab.</p></body></html>";
            msg.set_status (Soup.Status.OK, null);
            msg.set_response ("text/html; charset=utf-8", Soup.MemoryUse.COPY, body.data);
            Idle.add (() => {
                loop.quit ();
                return false;
            });
        });

        server.listen_local (0, Soup.ServerListenOptions.IPV4_ONLY);
        var uris = server.get_uris ();
        if (uris == null || uris.length () == 0) {
            throw new OAuthError.HTTP ("Could not bind localhost OAuth redirect server");
        }
        var listen_port = (uint16) uris.data.get_port ();
        var redirect = "http://127.0.0.1:%u/letter-oauth".printf (listen_port);

        var auth_url = "https://login.microsoftonline.com/%s/oauth2/v2.0/authorize?%s".printf (
            Uri.escape_string (this.tenant),
            "client_id=%s&response_type=code&redirect_uri=%s&response_mode=query&scope=%s&state=%s&code_challenge=%s&code_challenge_method=S256".printf (
                Uri.escape_string (this.client_id),
                Uri.escape_string (redirect),
                Uri.escape_string (this.scope),
                Uri.escape_string (state),
                Uri.escape_string (challenge)
            )
        );

        stdout.printf ("OAuth PKCE: open this URL in a browser (or wait for xdg-open):\n%s\n\n", auth_url);
        stdout.printf ("Redirect URI (add in Azure app if required): %s\n", redirect);
        stdout.printf ("Listening on %s …\n", redirect);

        try {
            AppInfo.launch_default_for_uri (auth_url, null);
        } catch (GLib.Error e) {
            stdout.printf ("(Could not auto-open browser: %s)\n", e.message);
        }

        ulong cancel_id = 0;
        if (cancellable != null) {
            cancel_id = cancellable.connect (() => {
                oauth_error = "cancelled";
                loop.quit ();
            });
        }

        loop.run ();

        if (cancellable != null && cancel_id != 0)
            cancellable.disconnect (cancel_id);

        try {
            server.disconnect ();
        } catch (GLib.Error e) {
        }

        if (oauth_error != null && oauth_error.length > 0) {
            throw new OAuthError.CANCELLED ("OAuth error: %s".printf (oauth_error));
        }
        if (auth_code == null || auth_code.length == 0) {
            throw new OAuthError.TOKEN ("No authorization code received");
        }
        if (returned_state != state) {
            throw new OAuthError.STATE ("OAuth state mismatch");
        }

        return yield exchange_code (auth_code, redirect, verifier, cancellable);
    }

    /**
     * Device code flow — no localhost listener. Better Flatpak fallback:
     * user opens the verification URL in the host browser and enters the code.
     */
    public async TokenSet authorize_device_code (Cancellable? cancellable = null) throws GLib.Error {
        var device_url = "https://login.microsoftonline.com/%s/oauth2/v2.0/devicecode".printf (this.tenant);
        var form = "client_id=%s&scope=%s".printf (
            Uri.escape_string (this.client_id),
            Uri.escape_string (this.scope)
        );
        var msg = new Soup.Message.from_encoded_form ("POST", device_url, form);
        Bytes bytes;
        try {
            bytes = yield this.session.send_and_read_async (msg, Priority.DEFAULT, cancellable);
        } catch (GLib.Error e) {
            throw new OAuthError.HTTP ("Device code request failed: %s".printf (e.message));
        }
        if (msg.status_code < 200 || msg.status_code >= 300) {
            throw new OAuthError.TOKEN (
                "Device code HTTP %u: %s".printf (msg.status_code, bytes_to_string (bytes))
            );
        }

        var parser = new Json.Parser ();
        parser.load_from_data (bytes_to_string (bytes));
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new OAuthError.TOKEN ("Invalid device code JSON");
        }
        var obj = root.get_object ();
        if (obj.has_member ("error")) {
            throw new OAuthError.TOKEN (
                "Device code error: %s".printf (obj.get_string_member ("error"))
            );
        }

        var device_code = obj.get_string_member ("device_code");
        var user_code = obj.get_string_member ("user_code");
        var verification_uri = obj.has_member ("verification_uri")
            ? obj.get_string_member ("verification_uri")
            : "https://microsoft.com/devicelogin";
        var interval = obj.has_member ("interval") ? (int) obj.get_int_member ("interval") : 5;
        if (interval < 1)
            interval = 5;
        var expires_in = obj.has_member ("expires_in") ? (int) obj.get_int_member ("expires_in") : 900;

        stdout.printf ("OAuth device code (Flatpak-friendly):\n");
        stdout.printf ("  1. Open: %s\n", verification_uri);
        stdout.printf ("  2. Enter code: %s\n", user_code);
        stdout.printf ("Waiting for approval (up to %d s, poll every %d s)…\n", expires_in, interval);

        try {
            AppInfo.launch_default_for_uri (verification_uri, null);
        } catch (GLib.Error e) {
            stdout.printf ("(Could not auto-open browser: %s)\n", e.message);
        }

        var token_url = "https://login.microsoftonline.com/%s/oauth2/v2.0/token".printf (this.tenant);
        var deadline = new DateTime.now_utc ().to_unix () + expires_in;

        while (new DateTime.now_utc ().to_unix () < deadline) {
            if (cancellable != null && cancellable.is_cancelled ()) {
                throw new OAuthError.CANCELLED ("Device code cancelled");
            }

            yield sleep_seconds (interval, cancellable);

            var poll_body = "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=%s&device_code=%s".printf (
                Uri.escape_string (this.client_id),
                Uri.escape_string (device_code)
            );
            var poll = new Soup.Message.from_encoded_form ("POST", token_url, poll_body);
            Bytes poll_bytes;
            try {
                poll_bytes = yield this.session.send_and_read_async (poll, Priority.DEFAULT, cancellable);
            } catch (GLib.Error e) {
                throw new OAuthError.HTTP ("Device token poll failed: %s".printf (e.message));
            }

            var text = bytes_to_string (poll_bytes);
            var poll_parser = new Json.Parser ();
            poll_parser.load_from_data (text);
            var poll_root = poll_parser.get_root ();
            if (poll_root == null || poll_root.get_node_type () != Json.NodeType.OBJECT)
                continue;
            var poll_obj = poll_root.get_object ();

            if (poll_obj.has_member ("access_token"))
                return parse_token_json (text);

            if (!poll_obj.has_member ("error"))
                continue;

            var err = poll_obj.get_string_member ("error");
            if (err == "authorization_pending" || err == "slow_down") {
                if (err == "slow_down")
                    interval += 5;
                continue;
            }
            if (err == "expired_token") {
                throw new OAuthError.TOKEN ("Device code expired; run again");
            }
            throw new OAuthError.TOKEN (
                "Device code error: %s (%s)".printf (
                    err,
                    poll_obj.has_member ("error_description")
                        ? poll_obj.get_string_member ("error_description") : ""
                )
            );
        }

        throw new OAuthError.TOKEN ("Device code timed out");
    }

    private static async void sleep_seconds (int seconds, Cancellable? cancellable) throws GLib.Error {
        var source = new TimeoutSource.seconds (seconds);
        source.set_callback (() => {
            sleep_seconds.callback ();
            return false;
        });
        source.attach (MainContext.default ());
        yield;
        if (cancellable != null && cancellable.is_cancelled ()) {
            throw new IOError.CANCELLED ("Cancelled");
        }
    }

    private async TokenSet exchange_code (
        string code,
        string redirect_uri,
        string verifier,
        Cancellable? cancellable
    ) throws GLib.Error {
        var token_url = "https://login.microsoftonline.com/%s/oauth2/v2.0/token".printf (this.tenant);
        var body = "client_id=%s&grant_type=authorization_code&code=%s&redirect_uri=%s&code_verifier=%s".printf (
            Uri.escape_string (this.client_id),
            Uri.escape_string (code),
            Uri.escape_string (redirect_uri),
            Uri.escape_string (verifier)
        );

        var msg = new Soup.Message.from_encoded_form ("POST", token_url, body);
        Bytes bytes;
        try {
            bytes = yield this.session.send_and_read_async (msg, Priority.DEFAULT, cancellable);
        } catch (GLib.Error e) {
            throw new OAuthError.HTTP ("Token request failed: %s".printf (e.message));
        }

        if (msg.status_code < 200 || msg.status_code >= 300) {
            var err_text = bytes_to_string (bytes);
            throw new OAuthError.TOKEN (
                "Token endpoint HTTP %u: %s".printf (msg.status_code, err_text)
            );
        }

        return parse_token_json (bytes_to_string (bytes));
    }

    public static TokenSet parse_token_json (string json_text) throws GLib.Error {
        var parser = new Json.Parser ();
        parser.load_from_data (json_text);
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new OAuthError.TOKEN ("Invalid token JSON");
        }
        var obj = root.get_object ();
        if (obj.has_member ("error")) {
            throw new OAuthError.TOKEN (
                "Token error: %s (%s)".printf (
                    obj.get_string_member ("error"),
                    obj.has_member ("error_description")
                        ? obj.get_string_member ("error_description") : ""
                )
            );
        }
        if (!obj.has_member ("access_token")) {
            throw new OAuthError.TOKEN ("Token JSON missing access_token");
        }

        return new TokenSet () {
            access_token = obj.get_string_member ("access_token"),
            refresh_token = obj.has_member ("refresh_token")
                ? obj.get_string_member ("refresh_token") : null,
            token_type = obj.has_member ("token_type")
                ? obj.get_string_member ("token_type") : null,
            expires_in = obj.has_member ("expires_in")
                ? (int64) obj.get_int_member ("expires_in") : 0,
        };
    }

    private static string bytes_to_string (Bytes bytes) {
        var data = bytes.get_data ();
        if (data == null || data.length == 0)
            return "";
        return (string) data;
    }
}
