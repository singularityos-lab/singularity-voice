using Gtk;

namespace Singularity.Apps.Voice {

    public class MiniWave : Widget {
        private const float BAR = 2f;
        private const float GAP = 1.5f;

        private float[] peaks = {};

        public MiniWave() {
            Object(css_name: "voice-mini-wave");
        }

        construct {
            add_css_class("voice-mini-wave");
            set_size_request(72, 28);
            valign = Align.CENTER;
            can_target = false;
        }

        public void set_peaks(float[] values) {
            peaks = values;
            queue_draw();
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            float w = get_width();
            float h = get_height();
            if (w <= 0 || h <= 0) return;
            int slots = int.max((int) ((w + GAP) / (BAR + GAP)), 1);
            var values = Peaks.bucket(peaks, slots);
            float low = 1;
            float high = 0;
            foreach (float v in values) {
                low = float.min(low, v);
                high = float.max(high, v);
            }
            float spread = high - low;
            var color = get_color();
            color.alpha = 0.55f;
            float mid = h / 2;
            float used = slots * (BAR + GAP) - GAP;
            float x0 = (w - used) / 2;
            var builder = new Gsk.PathBuilder();
            for (int i = 0; i < slots; i++) {
                float level = 0;
                if (spread >= 0.05f) level = 0.2f + 0.8f * (values[i] - low) / spread;
                else if (high > 0) level = 0.8f * values[i] / high;
                float bar = float.max(level * mid, 1f);
                var rounded = Gsk.RoundedRect();
                rounded.init_from_rect(Graphene.Rect().init(x0 + i * (BAR + GAP), mid - bar, BAR, bar * 2), BAR / 2);
                builder.add_rounded_rect(rounded);
            }
            snapshot.append_fill(builder.to_path(), Gsk.FillRule.WINDING, color);
        }
    }

    public delegate void RecordingMenuFunc(Widget anchor, double x, double y, Recording recording);

    public void attach_recording_menu(Widget widget, Recording recording, owned RecordingMenuFunc open) {
        var click = new GestureClick();
        click.button = Gdk.BUTTON_SECONDARY;
        click.pressed.connect((n, x, y) => {
            click.set_state(EventSequenceState.CLAIMED);
            open(widget, x, y, recording);
        });
        widget.add_controller(click);
        var hold = new GestureLongPress();
        hold.touch_only = true;
        hold.pressed.connect((x, y) => {
            hold.set_state(EventSequenceState.CLAIMED);
            open(widget, x, y, recording);
        });
        widget.add_controller(hold);
        var keys = new EventControllerKey();
        keys.key_pressed.connect((keyval, code, state) => {
            bool shift_f10 = keyval == Gdk.Key.F10 && (state & Gdk.ModifierType.SHIFT_MASK) != 0;
            if (keyval != Gdk.Key.Menu && !shift_f10) return false;
            open(widget, widget.get_width() / 2, widget.get_height() / 2, recording);
            return true;
        });
        widget.add_controller(keys);
    }

    public class RecordingCard : Button {
        public Recording recording { get; construct; }
        private MiniWave wave;
        private Label title_label;
        private Label date_label;
        private Label length_label;

        public RecordingCard(Recording recording) {
            Object(recording: recording);
            has_frame = false;
            add_css_class("welcome-page-row");
            add_css_class("voice-recent-row");
            var row = new Box(Orientation.HORIZONTAL, 14);
            row.margin_top = 10;
            row.margin_bottom = 10;
            row.margin_start = 14;
            row.margin_end = 14;
            wave = new MiniWave();
            var texts = new Box(Orientation.VERTICAL, 2);
            texts.hexpand = true;
            texts.valign = Align.CENTER;
            title_label = new Label("");
            title_label.xalign = 0;
            title_label.ellipsize = Pango.EllipsizeMode.END;
            title_label.add_css_class("heading");
            date_label = new Label("");
            date_label.xalign = 0;
            date_label.ellipsize = Pango.EllipsizeMode.END;
            date_label.add_css_class("caption");
            date_label.add_css_class("dim-label");
            texts.append(title_label);
            texts.append(date_label);
            length_label = new Label("");
            length_label.valign = Align.CENTER;
            length_label.add_css_class("caption");
            length_label.add_css_class("dim-label");
            length_label.add_css_class("voice-clock");
            row.append(wave);
            row.append(texts);
            row.append(length_label);
            child = row;
            recording.changed.connect(sync);
            sync();
        }

        private void sync() {
            title_label.label = recording.title;
            date_label.label = recording.date_text();
            length_label.label = Timecode.format(recording.duration);
            wave.set_peaks(recording.peaks);
            update_property(Gtk.AccessibleProperty.LABEL,
                "%s, %s, %s".printf(recording.title, recording.date_text(), Timecode.format(recording.duration)), -1);
        }
    }
}
