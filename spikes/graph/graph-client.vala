/** Minimal Microsoft Graph mail client (REST). No Camel / evolution-ews. */
public errordomain LetterGraph.ApiError {
    HTTP,
    JSON
}

public class LetterGraph.Client : Object {
    private Soup.Session session;
    private string access_token;

    public Client (string access_token) {
        this.access_token = access_token;
        this.session = new Soup.Session ();
    }

    public async string get_me_display (Cancellable? cancellable = null) throws GLib.Error {
        var obj = yield get_json ("/v1.0/me?$select=displayName,mail,userPrincipalName", cancellable);
        var name = obj.has_member ("displayName") ? obj.get_string_member ("displayName") : "?";
        string mail = "?";
        if (obj.has_member ("mail") && obj.get_member ("mail") != null
            && !obj.get_member ("mail").is_null ()) {
            mail = obj.get_string_member ("mail");
        } else if (obj.has_member ("userPrincipalName")) {
            mail = obj.get_string_member ("userPrincipalName");
        }
        return "%s <%s>".printf (name, mail);
    }

    public class Folder : Object {
        public string id { get; set; }
        public string display_name { get; set; }
        public int64 total_item_count { get; set; }
    }

    public async GenericArray<Folder> list_mail_folders (Cancellable? cancellable = null) throws GLib.Error {
        var obj = yield get_json (
            "/v1.0/me/mailFolders?$top=50&$select=id,displayName,totalItemCount",
            cancellable
        );
        var list = new GenericArray<Folder> ();
        if (!obj.has_member ("value"))
            return list;
        foreach (var node in obj.get_array_member ("value").get_elements ()) {
            var o = node.get_object ();
            list.add (new Folder () {
                id = o.get_string_member ("id"),
                display_name = o.get_string_member ("displayName"),
                total_item_count = o.has_member ("totalItemCount")
                    ? o.get_int_member ("totalItemCount") : 0,
            });
        }
        return list;
    }

    public class MessageHeader : Object {
        public string id { get; set; }
        public string? subject { get; set; }
        public string? from { get; set; }
        public string? received { get; set; }
    }

    public async GenericArray<MessageHeader> list_inbox_headers (
        uint top = 5,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var path = "/v1.0/me/mailFolders/inbox/messages?$top=%u&$select=id,subject,from,receivedDateTime&$orderby=receivedDateTime%%20desc".printf (top);
        var obj = yield get_json (path, cancellable);
        var list = new GenericArray<MessageHeader> ();
        if (!obj.has_member ("value"))
            return list;
        foreach (var node in obj.get_array_member ("value").get_elements ()) {
            var o = node.get_object ();
            string? from = null;
            if (o.has_member ("from") && o.get_member ("from") != null
                && !o.get_member ("from").is_null ()) {
                var from_o = o.get_object_member ("from");
                if (from_o.has_member ("emailAddress")) {
                    var ea = from_o.get_object_member ("emailAddress");
                    var n = ea.has_member ("name") ? ea.get_string_member ("name") : "";
                    var a = ea.has_member ("address") ? ea.get_string_member ("address") : "";
                    from = "%s <%s>".printf (n, a);
                }
            }
            string? subject = null;
            if (o.has_member ("subject") && o.get_member ("subject") != null
                && !o.get_member ("subject").is_null ()) {
                subject = o.get_string_member ("subject");
            }
            list.add (new MessageHeader () {
                id = o.get_string_member ("id"),
                subject = subject,
                from = from,
                received = o.has_member ("receivedDateTime")
                    ? o.get_string_member ("receivedDateTime") : null,
            });
        }
        return list;
    }

    public async string fetch_body_preview (string message_id, Cancellable? cancellable = null) throws GLib.Error {
        var path = "/v1.0/me/messages/%s?$select=subject,body".printf (
            Uri.escape_string (message_id)
        );
        var obj = yield get_json (path, cancellable);
        if (!obj.has_member ("body") || obj.get_member ("body") == null
            || obj.get_member ("body").is_null ()) {
            return "";
        }
        var body = obj.get_object_member ("body");
        var content = body.has_member ("content") ? body.get_string_member ("content") : "";
        return content;
    }

    private async Json.Object get_json (string path, Cancellable? cancellable) throws GLib.Error {
        var url = "https://graph.microsoft.com" + path;
        var msg = new Soup.Message ("GET", url);
        msg.request_headers.append ("Authorization", "Bearer " + this.access_token);
        msg.request_headers.append ("Accept", "application/json");

        Bytes bytes;
        try {
            bytes = yield this.session.send_and_read_async (msg, Priority.DEFAULT, cancellable);
        } catch (GLib.Error e) {
            throw new ApiError.HTTP ("Graph GET failed: %s".printf (e.message));
        }

        var text = bytes_to_string (bytes);
        if (msg.status_code < 200 || msg.status_code >= 300) {
            throw new ApiError.HTTP ("Graph HTTP %u: %s".printf (msg.status_code, text));
        }

        var parser = new Json.Parser ();
        parser.load_from_data (text);
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new ApiError.JSON ("Graph response is not a JSON object");
        }
        return root.get_object ();
    }

    private static string bytes_to_string (Bytes bytes) {
        var data = bytes.get_data ();
        if (data == null || data.length == 0)
            return "";
        return (string) data;
    }
}
