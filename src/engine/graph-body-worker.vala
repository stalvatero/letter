/**
 * Formal Graph I2 BodyWorker (Regole Globali).
 *
 * Interactive walks (I1/I3/I4 headers, I5 on-demand) mark activity. Background
 * body prefetch for non-open folders waits until the mailbox has been idle for
 * IDLE_SECONDS. Prefetch for the folder the user just opened runs immediately
 * (preference window) — I5 load_message never goes through this worker.
 */
public class Mail.GraphBodyWorker : Object {
    public const uint IDLE_SECONDS = 30;

    private int interactive_depth;
    private int64 last_activity_us;

    public GraphBodyWorker () {
        this.interactive_depth = 0;
        this.last_activity_us = get_monotonic_time ();
    }

    public void begin_interactive () {
        this.interactive_depth++;
        this.last_activity_us = get_monotonic_time ();
    }

    public void end_interactive () {
        if (this.interactive_depth > 0)
            this.interactive_depth--;
        this.last_activity_us = get_monotonic_time ();
    }

    public bool is_busy () {
        return this.interactive_depth > 0;
    }

    public bool idle_ready () {
        if (this.interactive_depth > 0)
            return false;
        var idle_us = get_monotonic_time () - this.last_activity_us;
        return idle_us >= ((int64) IDLE_SECONDS * TimeSpan.SECOND);
    }

    /* Open-folder I4 preference window: do not wait for idle. Background
     * I1/I3 waves for other folders must be idle-ready. */
    public bool may_prefetch (bool open_folder_preference) {
        if (open_folder_preference)
            return !is_busy ();
        return idle_ready ();
    }
}
