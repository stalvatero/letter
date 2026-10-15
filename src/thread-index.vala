/* The thread lookup over cached headers, indexed.
 *
 * Built from the lists the lookup walks, in walk order (folders in tree
 * order, each folder's headers in list order). expand () returns exactly
 * what that walk returns: two passes in walk order, a message joining when
 * it shares a Message-ID, a reference or a conversation key with what has
 * joined so far, unless one with the same folder and UID is already in.
 * Instead of testing every message, it only visits those that share a key,
 * in walk order, so a lookup costs the size of the threads it finds.
 *
 * The index holds on to the messages, so it is only valid while the lists
 * it was built from stay the same. */
public class Mail.ThreadIndex : Object {
    private GenericArray<Message> messages = new GenericArray<Message> ();
    /* Per position: its keys (message_keys[keys_start[pos]..keys_start[pos + 1]]),
     * and which folder and UID it is. */
    private int[] keys_start = {};
    private int[] message_keys = {};
    private int[] flag_ids = {};
    /* Per key: the positions that have it, ascending. */
    private int[] postings_start = {};
    private int[] postings = {};
    /* Ids are stored + 1 so a missing entry (0) stays apart from id 0. */
    private HashTable<string, int> hash_keys = new HashTable<string, int> (str_hash, str_equal);
    private HashTable<string, int> conversation_keys = new HashTable<string, int> (str_hash, str_equal);
    private HashTable<string, int> flag_keys = new HashTable<string, int> (str_hash, str_equal);
    private HashTable<Message, int> positions = new HashTable<Message, int> (direct_hash, direct_equal);
    private int key_count;
    private int flag_count;

    /* Scratch for one expand (). */
    private bool[] joined_keys;
    private bool[] taken;
    private uint8[] state;
    private int[] heap;
    private int heap_length;
    private int[] behind;
    private int pass;
    private int cursor;

    private const uint8 QUEUED = 1;
    private const uint8 BEHIND = 2;

    public ThreadIndex (GenericArray<GenericArray<Message>> lists) {
        for (uint i = 0; i < lists.length; i++) {
            var list = lists[i];
            for (uint j = 0; j < list.length; j++)
                add (list[j]);
        }
        this.keys_start += this.message_keys.length;

        var counts = new int[this.key_count + 1];
        for (int k = 0; k < this.message_keys.length; k++)
            counts[this.message_keys[k] + 1]++;
        for (int k = 0; k < this.key_count; k++)
            counts[k + 1] += counts[k];
        this.postings_start = counts;
        this.postings = new int[this.message_keys.length];
        var fill = new int[this.key_count];
        for (int pos = 0; pos < this.messages.length; pos++) {
            for (int k = this.keys_start[pos]; k < this.keys_start[pos + 1]; k++) {
                var key = this.message_keys[k];
                this.postings[this.postings_start[key] + fill[key]] = pos;
                fill[key]++;
            }
        }
    }

    public uint length {
        get {
            return this.messages.length;
        }
    }

    public static string flag_key (Message message) {
        return "%s\n%s".printf (message.folder_full_name ?? "", message.uid);
    }

    private void add (Message message) {
        int pos = (int) this.messages.length;
        this.messages.add (message);
        if (!this.positions.contains (message))
            this.positions.set (message, pos + 1);

        var flag = flag_key (message);
        var flag_id = this.flag_keys.get (flag);
        if (flag_id == 0) {
            flag_id = ++this.flag_count;
            this.flag_keys.set (flag, flag_id);
        }
        this.flag_ids += flag_id - 1;

        this.keys_start += this.message_keys.length;
        if (message.conversation_key != null && message.conversation_key.length > 0)
            this.message_keys += key_id (this.conversation_keys, message.conversation_key);
        if (message.msgid_hash != 0)
            this.message_keys += key_id (this.hash_keys, message.msgid_hash.to_string ());
        var refs = message.msgid_refs;
        if (refs != null) {
            for (int i = 0; i < refs.length; i++) {
                if (refs[i] != 0)
                    this.message_keys += key_id (this.hash_keys, refs[i].to_string ());
            }
        }
    }

    private int key_id (HashTable<string, int> table, string key) {
        var id = table.get (key);
        if (id == 0) {
            id = ++this.key_count;
            table.set (key, id);
        }
        return id - 1;
    }

    /* The other messages of the threads the hits belong to. */
    public GenericArray<Message> expand (GenericArray<Message> hits) {
        var extras = new GenericArray<Message> ();
        this.joined_keys = new bool[this.key_count];
        this.taken = new bool[this.flag_count];
        this.state = new uint8[this.messages.length];
        this.heap = new int[64];
        this.heap_length = 0;
        this.behind = {};
        this.pass = 0;
        this.cursor = -1;

        for (uint i = 0; i < hits.length; i++)
            seed (hits[i]);
        drain (extras);

        /* The second pass sees every key the first one found, so it picks
         * up what the first had already passed when the key turned up. */
        this.pass = 1;
        this.cursor = -1;
        for (int i = 0; i < this.behind.length; i++)
            push (this.behind[i]);
        drain (extras);

        this.joined_keys = null;
        this.taken = null;
        this.state = null;
        this.heap = null;
        this.behind = null;
        return extras;
    }

    private void seed (Message hit) {
        var pos = this.positions.get (hit) - 1;
        if (pos >= 0) {
            this.taken[this.flag_ids[pos]] = true;
            join_keys_of (pos);
            return;
        }

        /* Not in the walk: look its keys up instead. Keys no message in the
         * walk has cannot match anything, so they can be left out. */
        var flag_id = this.flag_keys.get (flag_key (hit));
        if (flag_id > 0)
            this.taken[flag_id - 1] = true;
        if (hit.conversation_key != null && hit.conversation_key.length > 0)
            join_known (this.conversation_keys, hit.conversation_key);
        if (hit.msgid_hash != 0)
            join_known (this.hash_keys, hit.msgid_hash.to_string ());
        var refs = hit.msgid_refs;
        if (refs != null) {
            for (int i = 0; i < refs.length; i++) {
                if (refs[i] != 0)
                    join_known (this.hash_keys, refs[i].to_string ());
            }
        }
    }

    private void join_known (HashTable<string, int> table, string key) {
        var id = table.get (key);
        if (id > 0)
            join (id - 1);
    }

    private void drain (GenericArray<Message> extras) {
        while (this.heap_length > 0) {
            var pos = pop ();
            this.cursor = pos;
            var flag_id = this.flag_ids[pos];
            if (this.taken[flag_id])
                continue;
            this.taken[flag_id] = true;
            extras.add (this.messages[pos]);
            join_keys_of (pos);
        }
    }

    private void join_keys_of (int pos) {
        for (int k = this.keys_start[pos]; k < this.keys_start[pos + 1]; k++)
            join (this.message_keys[k]);
    }

    private void join (int key) {
        if (this.joined_keys[key])
            return;
        this.joined_keys[key] = true;
        for (int p = this.postings_start[key]; p < this.postings_start[key + 1]; p++) {
            var pos = this.postings[p];
            if (this.state[pos] != 0)
                continue;
            if (pos > this.cursor) {
                /* Ahead of the walk: it will match when the walk gets there. */
                this.state[pos] = QUEUED;
                push (pos);
            } else if (this.pass == 0) {
                this.state[pos] = BEHIND;
                this.behind += pos;
            }
            /* Behind the walk in the second pass: there is no third. */
        }
    }

    private void push (int pos) {
        if (this.heap_length == this.heap.length)
            this.heap.resize (this.heap.length * 2);
        var i = this.heap_length++;
        while (i > 0) {
            var parent = (i - 1) / 2;
            if (this.heap[parent] <= pos)
                break;
            this.heap[i] = this.heap[parent];
            i = parent;
        }
        this.heap[i] = pos;
    }

    private int pop () {
        var top = this.heap[0];
        var last = this.heap[--this.heap_length];
        var i = 0;
        while (true) {
            var child = i * 2 + 1;
            if (child >= this.heap_length)
                break;
            if (child + 1 < this.heap_length && this.heap[child + 1] < this.heap[child])
                child++;
            if (this.heap[child] >= last)
                break;
            this.heap[i] = this.heap[child];
            i = child;
        }
        this.heap[i] = last;
        return top;
    }
}
