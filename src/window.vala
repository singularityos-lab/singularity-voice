using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Voice {

    public class RecordingRow : ListBoxRow {
        public Recording recording { get; construct; }
        private Label title;
        private Label subtitle;
        private Label length;

        public RecordingRow(Recording recording) {
            Object(recording: recording);
            var row = new Box(Orientation.HORIZONTAL, 8);
            row.margin_top = 6;
            row.margin_bottom = 6;
            row.margin_start = 6;
            row.margin_end = 6;
            var box = new Box(Orientation.VERTICAL, 2);
            box.hexpand = true;
            title = new Label("");
            title.xalign = 0;
            title.ellipsize = Pango.EllipsizeMode.END;
            title.add_css_class("voice-row-title");
            subtitle = new Label("");
            subtitle.xalign = 0;
            subtitle.ellipsize = Pango.EllipsizeMode.END;
            subtitle.add_css_class("dim-label");
            subtitle.add_css_class("caption");
            box.append(title);
            box.append(subtitle);
            length = new Label("");
            length.valign = Align.CENTER;
            length.add_css_class("dim-label");
            length.add_css_class("caption");
            length.add_css_class("voice-clock");
            row.append(box);
            row.append(length);
            child = Singularity.Animation.ListAnimator.wrap(row);
            recording.changed.connect(sync);
            sync();
        }

        private void sync() {
            title.label = recording.title;
            subtitle.label = recording.short_date_text();
            length.label = Timecode.format(recording.duration);
            update_property(Gtk.AccessibleProperty.LABEL,
                "%s, %s, %s".printf(recording.title, recording.date_text(), Timecode.format(recording.duration)), -1);
        }
    }

    public class VoiceWindow : Singularity.Widgets.Window {
        private VoiceApp app;
        private Library library;
        private Recorder recorder = new Recorder();
        private Player player = new Player();
        private Transcoder? job = null;
        private TranscriptionBackend? transcriber = null;
        private Cancellable? transcribing = null;

        private const int RECENT_LIMIT = 6;

        private AppSidebar sidebar;
        private ListBox list;
        private Singularity.Widgets.SearchEntry search;
        private StatusPage no_results;
        private WelcomePage welcome;
        private Box recent_list;
        private Box recent_empty;
        private Popover? welcome_devices = null;
        private bool sidebar_shown = false;
        private Singularity.Animation.ListAnimator animator;
        private Stack stack;
        private Recording? current = null;
        private string pending_file = "";
        private uint tick_id = 0;

        private Label rec_time;
        private Label rec_device;
        private Widget rec_dot;
        private WaveformView rec_wave;
        private Button pause_button;

        private Label detail_title;
        private Label detail_meta;
        private WaveformView detail_wave;
        private Label pos_label;
        private Label len_label;
        private Button play_button;
        private Button speed_button;
        private PreferencesGroup transcript_group;
        private Label transcript_label;
        private ActionRow transcribe_row;
        private Button transcribe_button;
        private Button copy_transcript;

        private TrimRange? range = null;
        private WaveformView trim_wave;
        private Label trim_span;
        private Label trim_result;
        private SegmentedControl trim_switch;
        private Box trim_buttons;
        private Button trim_play;
        private ProgressBar trim_progress;
        private TrimMode trim_mode = TrimMode.KEEP;

        private Button back_bubble;
        private Button record_bubble;
        private Button input_bubble;
        private Button trim_bubble;
        private Button export_bubble;
        private Button share_bubble;
        private Button delete_bubble;
        private Popover device_popover;

        public VoiceWindow(VoiceApp app) {
            Object(application: app);
            this.app = app;
            library = app.library;
            set_title(_("Recorder"));
            set_default_size(980, 640);

            sidebar = new AppSidebar(250);
            search = new Singularity.Widgets.SearchEntry();
            search.placeholder_text = _("Search Recordings");
            search.margin_bottom = 6;
            search.search_changed.connect(() => {
                list.invalidate_filter();
                list.invalidate_headers();
                sync_no_results();
            });
            sidebar.box.append(search);
            list = new ListBox();
            list.add_css_class("navigation-sidebar");
            list.selection_mode = SelectionMode.SINGLE;
            list.set_filter_func((row) => {
                var item = row as RecordingRow;
                return item == null || Search.matches(search.text, item.recording.title, item.recording.transcript);
            });
            list.set_header_func(update_header);
            list.row_selected.connect((row) => {
                var item = row as RecordingRow;
                if (item != null && item.recording != current) show_recording(item.recording);
            });
            sidebar.box.append(list);
            no_results = new StatusPage();
            no_results.compact = true;
            no_results.icon_name = "system-search";
            no_results.title = _("No Results");
            no_results.description = _("Try another name, or a word said in a transcript.");
            no_results.visible = false;
            sidebar.box.append(no_results);
            animator = new Singularity.Animation.ListAnimator(list);
            set_sidebar(sidebar);
            set_sidebar_visible(false);
            foreach (var recording in library.items) list.append(make_row(recording));
            library.added.connect((recording) => {
                var row = make_row(recording);
                animator.insert(row, () => {
                    list.prepend(row);
                    list.invalidate_headers();
                });
                fill_recent();
            });
            library.removed.connect((recording) => {
                var row = row_for(recording);
                if (row != null) animator.remove(row, () => {
                    list.remove(row);
                    list.invalidate_headers();
                    sync_no_results();
                });
                fill_recent();
            });

            stack = new Stack();
            stack.transition_type = StackTransitionType.NONE;
            stack.add_named(wrap(build_welcome()), "welcome");
            stack.add_named(wrap(build_recording()), "recording");
            stack.add_named(wrap(build_detail()), "detail");
            stack.add_named(wrap(build_trim()), "trim");
            set_content(stack);

            back_bubble = add_bubble_icon("go-previous-symbolic", _("Close Recording"), () => show_start());
            record_bubble = add_bubble_suggested(_("Record"), () => start_recording());
            device_popover = new Popover();
            var header_picker = new DevicePicker(app);
            header_picker.chosen.connect(() => device_popover.popdown());
            device_popover.child = header_picker;
            input_bubble = add_bubble_menu("audio-input-microphone-symbolic", _("Microphone"), device_popover);
            trim_bubble = add_bubble_icon("edit-cut-symbolic", _("Trim"), () => open_trim());
            export_bubble = add_bubble_icon("document-save-as-symbolic", _("Export"), () => open_export());
            share_bubble = add_bubble_icon("singularity-share-symbolic", _("Share"), () => share(current));
            delete_bubble = add_bubble_icon("user-trash-symbolic", _("Delete"), () => confirm_delete(current));

            var entries = new ActionEntry[] {
                { "close", () => close() },
                { "export", () => open_export() },
                { "share", () => share(current) },
                { "rename", () => open_rename(current) },
                { "trim", () => open_trim() },
                { "transcribe", () => transcribe.begin() },
                { "delete", () => confirm_delete(current) },
                { "show-in-files", () => show_in_files(current) },
                { "search", () => focus_search() },
                { "play", () => toggle_play() },
                { "speed", on_speed, "d", "1.0" },
                { "pause", () => toggle_pause() },
                { "finish", () => recorder.stop() },
                { "discard", () => confirm_discard() }
            };
            add_action_entries(entries, this);

            recorder.peak.connect((value) => {
                rec_wave.push_live(value);
                rec_time.label = Timecode.format(recorder.elapsed, true);
            });
            recorder.notify["state"].connect(sync);
            recorder.finished.connect(on_recorded);
            player.notify["playing"].connect(() => {
                sync_play();
                trim_play.label = player.playing ? _("Stop") : _("Play Selection");
                if (player.playing) start_ticks();
            });
            player.ended.connect(() => {
                sync_play();
                update_position();
            });
            detail_wave.seek_requested.connect((position) => {
                player.seek(position);
                detail_wave.position = position;
                update_position();
            });

            var connection = app.get_dbus_connection();
            transcriber = Transcript.locate(connection);
            if (connection != null) {
                Bus.watch_name_on_connection(connection, DictationBusBackend.BUS_NAME, BusNameWatcherFlags.NONE,
                    () => relocate_transcriber(connection), () => relocate_transcriber(connection));
            }

            app.settings.changed["input-device"].connect(sync_device_row);
            app.devices.changed.connect(sync_device_row);
            show_page("welcome");
        }

        private RecordingRow make_row(Recording recording) {
            var row = new RecordingRow(recording);
            attach_recording_menu(row, recording, open_recording_menu);
            recording.changed.connect(() => {
                row.changed();
                list.invalidate_headers();
            });
            return row;
        }

        private void update_header(ListBoxRow row, ListBoxRow? before) {
            var item = row as RecordingRow;
            var previous = before as RecordingRow;
            if (item == null) return;
            var now = new DateTime.now_local();
            string key = DateGroups.key(new DateTime.from_unix_local(item.recording.created), now);
            if (previous != null && DateGroups.key(new DateTime.from_unix_local(previous.recording.created), now) == key) {
                row.set_header(null);
                return;
            }
            var label = new SidebarSectionLabel(group_title(key));
            label.margin_top = previous == null ? 0 : 10;
            label.margin_bottom = 2;
            label.margin_start = 8;
            row.set_header(label);
        }

        private static string group_title(string key) {
            if (key == "today") return _("Today");
            if (key == "yesterday") return _("Yesterday");
            if (key == "week") return _("Previous 7 Days");
            var parts = key.split("-");
            var month = new DateTime.local(int.parse(parts[0]), int.parse(parts[1]), 1, 0, 0, 0);
            if (month.get_year() == new DateTime.now_local().get_year()) return month.format("%B");
            return month.format("%B %Y");
        }

        private void sync_no_results() {
            bool any = false;
            for (var child = list.get_first_child(); child != null; child = child.get_next_sibling()) {
                var row = child as RecordingRow;
                if (row != null && Search.matches(search.text, row.recording.title, row.recording.transcript)) {
                    any = true;
                    break;
                }
            }
            no_results.visible = !any && search.text.strip() != "";
            list.visible = any;
        }

        private void focus_search() {
            if (library.items.size == 0 || recorder.state != RecorderState.IDLE) return;
            if (stack.visible_child_name == "welcome") show_recording(library.items[0]);
            search.grab_focus();
        }

        private void open_recording_menu(Widget anchor, double x, double y, Recording recording) {
            if (recorder.state != RecorderState.IDLE || job != null) return;
            var menu = new ContextMenu(anchor);
            menu.set_pointing_to(Gdk.Rectangle() { x = (int) x, y = (int) y, width = 1, height = 1 });
            menu.add_item(_("Rename…"), "document-edit-symbolic", () => open_rename(recording));
            menu.add_item(_("Share…"), "singularity-share-symbolic", () => share(recording));
            menu.add_item(_("Show in Files"), "folder-open-symbolic", () => show_in_files(recording));
            menu.add_separator();
            menu.add_item(_("Delete…"), "user-trash-symbolic", () => confirm_delete(recording), "destructive-action");
            menu.closed.connect(() => Idle.add(() => {
                menu.unparent();
                return Source.REMOVE;
            }));
            menu.popup();
        }

        private void show_start() {
            if (recorder.state != RecorderState.IDLE) return;
            player.close();
            current = null;
            range = null;
            list.unselect_all();
            show_page("welcome");
        }

        private void sync_device_row() {
            welcome.set_action_description(1, _("Records from %s").printf(DevicePicker.current_label(app)));
        }

        private void open_welcome_devices() {
            var row = welcome.get_action_widget(1);
            if (row == null) return;
            if (welcome_devices == null) {
                welcome_devices = new Popover();
                var picker = new DevicePicker(app);
                picker.chosen.connect(() => welcome_devices.popdown());
                welcome_devices.child = picker;
                welcome_devices.position = PositionType.BOTTOM;
                welcome_devices.set_parent(welcome);
            }
            Graphene.Rect bounds;
            if (!row.compute_bounds(welcome, out bounds)) return;
            welcome_devices.child.width_request = int.max((int) bounds.size.width - 24, 240);
            welcome_devices.pointing_to = Gdk.Rectangle() {
                x = (int) bounds.origin.x,
                y = (int) bounds.origin.y,
                width = (int) bounds.size.width,
                height = (int) bounds.size.height
            };
            welcome_devices.popup();
        }

        private Widget build_recent() {
            var box = new Box(Orientation.VERTICAL, 12);
            box.add_css_class("voice-recent");
            var title = new Label(_("Recordings"));
            title.add_css_class("title-2");
            title.halign = Align.START;
            recent_list = new Box(Orientation.VERTICAL, 0);
            recent_list.add_css_class("welcome-page-list");
            recent_list.overflow = Overflow.HIDDEN;
            var hint = new StatusPage();
            hint.compact = true;
            hint.icon_name = "audio-x-generic";
            hint.title = _("No Recordings Yet");
            hint.description = _("Your recordings appear here, newest first.");
            recent_empty = new Box(Orientation.VERTICAL, 0);
            recent_empty.add_css_class("welcome-page-list");
            recent_empty.append(hint);
            box.append(title);
            box.append(recent_list);
            box.append(recent_empty);
            fill_recent();
            return box;
        }

        private Widget build_show_all(int total) {
            var button = new Button();
            button.has_frame = false;
            button.add_css_class("welcome-page-row");
            var row = new Box(Orientation.HORIZONTAL, 14);
            row.margin_top = 12;
            row.margin_bottom = 12;
            row.margin_start = 14;
            row.margin_end = 14;
            var label = new Label(_("Show All Recordings"));
            label.xalign = 0;
            label.hexpand = true;
            label.add_css_class("heading");
            var count = new Label(ngettext("%d recording", "%d recordings", total).printf(total));
            count.add_css_class("caption");
            count.add_css_class("dim-label");
            var chevron = new Image.from_icon_name("go-next-symbolic");
            chevron.add_css_class("dim-label");
            row.append(label);
            row.append(count);
            row.append(chevron);
            button.child = row;
            button.clicked.connect(() => focus_search());
            return button;
        }

        private void fill_recent() {
            if (recent_list == null) return;
            Widget? child;
            while ((child = recent_list.get_first_child()) != null) recent_list.remove(child);
            int shown = 0;
            foreach (var recording in library.items) {
                if (shown++ >= RECENT_LIMIT) break;
                var card = new RecordingCard(recording);
                card.clicked.connect(() => show_recording(card.recording));
                attach_recording_menu(card, recording, open_recording_menu);
                recent_list.append(card);
            }
            int total = library.items.size;
            if (total > RECENT_LIMIT) recent_list.append(build_show_all(total));
            recent_list.visible = total > 0;
            recent_empty.visible = total == 0;
        }

        private Singularity.Animation.MotionBin wrap(Widget page) {
            return new Singularity.Animation.MotionBin(page);
        }

        private RecordingRow? row_for(Recording recording) {
            for (var child = list.get_first_child(); child != null; child = child.get_next_sibling()) {
                var row = child as RecordingRow;
                if (row != null && row.recording == recording) return row;
            }
            return null;
        }

        private void show_page(string name) {
            bool wanted = name == "detail" && library.items.size > 0;
            if (wanted != sidebar_shown) {
                sidebar_shown = wanted;
                Idle.add(() => {
                    set_sidebar_visible(sidebar_shown);
                    return Source.REMOVE;
                });
            }
            if (stack.visible_child_name != name) {
                stack.visible_child_name = name;
                Singularity.Motion.reveal(stack.visible_child, Singularity.Motion.Preset.FADE_SLIDE);
            }
            sync();
        }

        private Widget build_welcome() {
            welcome = new WelcomePage();
            welcome.app_icon_name = "dev.sinty.voice";
            welcome.title = _("Recorder");
            welcome.subtitle = _("Record voice notes, lectures and meetings, then trim, export and share them.");
            welcome.add_action_with_caption("media-record", _("New Recording"),
                _("Start recording from the selected microphone"), "Ctrl+R", () => start_recording());
            welcome.add_action("audio-input-microphone", _("Choose a Microphone"),
                _("Records from %s").printf(DevicePicker.current_label(app)), () => open_welcome_devices());
            welcome.set_extra_widget(build_recent());
            return welcome;
        }

        private Widget build_recording() {
            var box = new Box(Orientation.VERTICAL, 18);
            box.add_css_class("voice-stage");
            box.valign = Align.CENTER;
            var status = new Box(Orientation.HORIZONTAL, 10);
            status.halign = Align.CENTER;
            rec_dot = new Box(Orientation.HORIZONTAL, 0);
            rec_dot.add_css_class("voice-record-dot");
            rec_dot.valign = Align.CENTER;
            rec_device = new Label("");
            rec_device.add_css_class("dim-label");
            status.append(rec_dot);
            status.append(rec_device);
            rec_time = new Label("0:00.0");
            rec_time.add_css_class("voice-time");
            rec_wave = new WaveformView();
            rec_wave.mode = WaveMode.LIVE;
            rec_wave.height_request = 150;
            var controls = new Box(Orientation.HORIZONTAL, 12);
            controls.halign = Align.CENTER;
            controls.margin_top = 12;
            var discard = new Button.with_label(_("Discard"));
            discard.add_css_class("pill");
            discard.clicked.connect(() => confirm_discard());
            pause_button = new Button.with_label(_("Pause"));
            pause_button.add_css_class("pill");
            pause_button.clicked.connect(() => toggle_pause());
            var done = new Button.with_label(_("Done"));
            done.add_css_class("pill");
            done.add_css_class("suggested-action");
            done.clicked.connect(() => recorder.stop());
            foreach (var b in new Button[] { discard, pause_button, done }) {
                b.width_request = 120;
                controls.append(b);
            }
            box.append(status);
            box.append(rec_time);
            box.append(rec_wave);
            box.append(controls);
            return box;
        }

        private Widget build_detail() {
            var box = new Box(Orientation.VERTICAL, 14);
            box.add_css_class("voice-stage");
            detail_title = new Label("");
            detail_title.add_css_class("voice-title");
            detail_title.xalign = 0;
            detail_title.ellipsize = Pango.EllipsizeMode.END;
            detail_meta = new Label("");
            detail_meta.add_css_class("dim-label");
            detail_meta.xalign = 0;
            var heading = new Box(Orientation.VERTICAL, 2);
            heading.append(detail_title);
            heading.append(detail_meta);
            box.append(heading);

            detail_wave = new WaveformView();
            detail_wave.mode = WaveMode.PLAYBACK;
            detail_wave.height_request = 140;
            detail_wave.margin_top = 12;
            box.append(detail_wave);

            var transport = new CenterBox();
            pos_label = new Label("0:00");
            pos_label.add_css_class("voice-clock");
            pos_label.add_css_class("dim-label");
            len_label = new Label("0:00");
            len_label.add_css_class("voice-clock");
            len_label.add_css_class("dim-label");
            var middle = new Box(Orientation.HORIZONTAL, 14);
            var back = new Button.from_icon_name("media-seek-backward-symbolic");
            back.tooltip_text = _("Back 10 Seconds");
            back.add_css_class("circular");
            back.valign = Align.CENTER;
            back.clicked.connect(() => skip(-10));
            play_button = new Button.from_icon_name("media-playback-start-symbolic");
            play_button.add_css_class("voice-play");
            play_button.add_css_class("suggested-action");
            play_button.tooltip_text = _("Play");
            play_button.clicked.connect(() => toggle_play());
            var forward = new Button.from_icon_name("media-seek-forward-symbolic");
            forward.tooltip_text = _("Forward 10 Seconds");
            forward.add_css_class("circular");
            forward.valign = Align.CENTER;
            forward.clicked.connect(() => skip(10));
            middle.append(back);
            middle.append(play_button);
            middle.append(forward);
            speed_button = new Button.with_label(speed_label(1.0));
            speed_button.tooltip_text = _("Playback Speed");
            speed_button.add_css_class("pill");
            speed_button.valign = Align.CENTER;
            var speed_menu = new GLib.Menu();
            foreach (double speed in SPEEDS) {
                var item = new GLib.MenuItem(speed_label(speed), null);
                item.set_action_and_target_value("win.speed", new Variant.double(speed));
                speed_menu.append_item(item);
            }
            var speed_popover = new PopoverMenu.from_model(speed_menu);
            speed_popover.set_parent(speed_button);
            speed_popover.has_arrow = false;
            speed_button.clicked.connect(() => speed_popover.popup());
            var left = new Box(Orientation.HORIZONTAL, 0);
            left.append(pos_label);
            left.valign = Align.CENTER;
            var right = new Box(Orientation.HORIZONTAL, 12);
            right.valign = Align.CENTER;
            right.append(len_label);
            right.append(speed_button);
            transport.start_widget = left;
            transport.center_widget = middle;
            transport.end_widget = right;
            box.append(transport);

            transcript_group = new PreferencesGroup(_("Transcript"));
            transcript_group.margin_top = 18;
            copy_transcript = new Button.from_icon_name("edit-copy-symbolic");
            copy_transcript.tooltip_text = _("Copy Transcript");
            copy_transcript.clicked.connect(() => {
                if (current == null) return;
                get_clipboard().set_text(current.transcript);
                add_toast(new Toast(_("Transcript copied")));
            });
            transcript_group.add_header_suffix(copy_transcript);
            transcript_label = new Label("");
            transcript_label.wrap = true;
            transcript_label.xalign = 0;
            transcript_label.selectable = true;
            transcript_label.add_css_class("voice-transcript");
            var transcript_row = new ListBoxRow();
            transcript_row.activatable = false;
            transcript_row.child = transcript_label;
            transcript_group.add_row(transcript_row);
            transcribe_row = new ActionRow(_("Transcribe This Recording"), "", "singularity-dictation");
            transcribe_button = new Button.with_label(_("Transcribe"));
            transcribe_button.valign = Align.CENTER;
            transcribe_button.clicked.connect(() => transcribe.begin());
            transcribe_row.add_suffix(transcribe_button);
            transcript_group.add_row(transcribe_row);
            box.append(transcript_group);

            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = box;
            return scroll;
        }

        private Widget build_trim() {
            var box = new Box(Orientation.VERTICAL, 16);
            box.add_css_class("voice-stage");
            box.valign = Align.CENTER;
            trim_span = new Label("");
            trim_span.add_css_class("voice-title");
            trim_span.add_css_class("voice-clock");
            trim_result = new Label("");
            trim_result.add_css_class("dim-label");
            trim_switch = new SegmentedControl();
            trim_switch.add_option("keep", _("Keep Selection"));
            trim_switch.add_option("remove", _("Remove Selection"));
            trim_switch.set_active("keep");
            trim_switch.halign = Align.CENTER;
            trim_switch.selected.connect((name) => {
                trim_mode = name == "remove" ? TrimMode.REMOVE : TrimMode.KEEP;
                trim_wave.trim_mode = trim_mode;
                sync_trim();
            });
            trim_wave = new WaveformView();
            trim_wave.mode = WaveMode.TRIM;
            trim_wave.height_request = 150;
            var hint = new Label(_("Drag the handles or across the waveform. The arrow keys move the start, Shift and the arrow keys move the end."));
            hint.add_css_class("dim-label");
            hint.add_css_class("caption");
            hint.wrap = true;
            hint.justify = Justification.CENTER;
            trim_progress = new ProgressBar();
            trim_progress.visible = false;

            trim_buttons = new Box(Orientation.HORIZONTAL, 12);
            trim_buttons.halign = Align.CENTER;
            trim_buttons.margin_top = 8;
            var preview = new Button.with_label(_("Play Selection"));
            trim_play = preview;
            var cancel = new Button.with_label(_("Cancel"));
            var copy = new Button.with_label(_("Save as Copy"));
            var apply = new Button.with_label(_("Trim"));
            apply.add_css_class("suggested-action");
            foreach (var b in new Button[] { preview, cancel, copy, apply }) {
                b.add_css_class("pill");
                b.width_request = 120;
                trim_buttons.append(b);
            }
            preview.clicked.connect(() => {
                if (range == null) return;
                if (player.playing) player.pause();
                else if (trim_mode == TrimMode.KEEP) player.play_range(range.start, range.end);
                else player.play_range(int64.max(range.start - 3 * NS_PER_SECOND, 0), int64.min(range.end + 3 * NS_PER_SECOND, range.duration));
                start_ticks();
            });
            cancel.clicked.connect(() => close_trim());
            copy.clicked.connect(() => trim_recording(current, range.start, range.end, trim_mode, true));
            apply.clicked.connect(() => trim_recording(current, range.start, range.end, trim_mode, false));

            box.append(trim_span);
            box.append(trim_result);
            box.append(trim_switch);
            box.append(trim_wave);
            box.append(hint);
            box.append(trim_progress);
            box.append(trim_buttons);
            return box;
        }

        private void sync() {
            string page = stack.visible_child_name ?? "welcome";
            bool idle = recorder.state == RecorderState.IDLE;
            bool detail = page == "detail" && current != null;
            back_bubble.visible = idle && detail;
            record_bubble.visible = idle && page != "trim";
            input_bubble.visible = idle && page != "trim";
            trim_bubble.visible = detail;
            export_bubble.visible = detail;
            share_bubble.visible = detail;
            delete_bubble.visible = detail;
            bool has = current != null && idle && job == null;
            foreach (string name in new string[] { "export", "share", "rename", "trim", "delete", "play", "show-in-files" }) {
                ((SimpleAction) lookup_action(name)).set_enabled(has);
            }
            ((SimpleAction) lookup_action("transcribe")).set_enabled(has && transcriber != null && transcribing == null);
            ((SimpleAction) lookup_action("search")).set_enabled(idle && library.items.size > 0);
            ((SimpleAction) lookup_action("pause")).set_enabled(!idle);
            ((SimpleAction) lookup_action("finish")).set_enabled(!idle);
            ((SimpleAction) lookup_action("discard")).set_enabled(!idle);
            list.sensitive = idle;
            bool paused = recorder.state == RecorderState.PAUSED;
            pause_button.label = paused ? _("Resume") : _("Pause");
            if (paused) {
                rec_dot.add_css_class("paused");
                rec_time.add_css_class("paused");
            } else {
                rec_dot.remove_css_class("paused");
                rec_time.remove_css_class("paused");
            }
        }

        public bool busy_recording() {
            if (recorder.state == RecorderState.IDLE) return false;
            confirm_discard();
            return true;
        }

        public void start_recording() {
            if (recorder.state != RecorderState.IDLE) return;
            player.pause();
            var device = app.devices.find(app.settings.get_string("input-device"));
            string file_name;
            string path = library.new_path(out file_name);
            rec_wave.reset_live();
            rec_time.label = "0:00.0";
            rec_device.label = device.label;
            try {
                recorder.start(device, path);
            } catch (Error e) {
                show_error(_("Recording Could Not Start"), e.message);
                return;
            }
            pending_file = file_name;
            list.unselect_all();
            show_page("recording");
        }

        private void toggle_pause() {
            if (recorder.state == RecorderState.RECORDING) recorder.pause();
            else if (recorder.state == RecorderState.PAUSED) recorder.resume();
        }

        private void confirm_discard() {
            if (recorder.state == RecorderState.IDLE) return;
            var dlg = new ConfirmDialog(app, _("Discard This Recording?"), "user-trash-symbolic",
                _("What was recorded so far will be lost."), _("Discard"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.set_secondary(_("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) recorder.cancel();
                else if (r == ConfirmDialog.Response.SECONDARY) recorder.stop();
            });
            dlg.present();
        }

        private void on_recorded(bool ok, string? error) {
            string file_name = pending_file;
            pending_file = "";
            if (!ok) {
                if (error != null) show_error(_("Recording Stopped"), error);
                if (current != null) show_recording(current);
                else show_page("welcome");
                return;
            }
            var peaks = recorder.take_peaks();
            int64 duration = Samples.to_ns(peaks.length, PEAKS_PER_SECOND);
            if (recorder.elapsed > 0) duration = recorder.elapsed;
            var recording = library.add(file_name, Titles.next(library.titles(), _("Recording")), duration, peaks);
            show_recording(recording);
            refine.begin(recording);
        }

        private async void refine(Recording recording) {
            var scan = new Transcoder();
            var result = yield scan.run(recording.file(library), null, null, {}, recording.duration);
            if (!result.ok || result.duration <= 0) return;
            recording.duration = result.duration;
            recording.peaks = result.peaks;
            library.save();
            recording.changed();
            if (current == recording) show_recording(recording);
        }

        public void show_recording(Recording? recording) {
            if (recording == null || recorder.state != RecorderState.IDLE) return;
            bool same = current == recording && player.uri != "";
            current = recording;
            detail_title.label = recording.title;
            detail_meta.label = "%s, %s".printf(recording.date_text(), Timecode.format(recording.duration));
            detail_wave.duration = recording.duration;
            detail_wave.set_peaks(recording.peaks);
            len_label.label = Timecode.format(recording.duration);
            if (!same) {
                player.open(recording.file(library), recording.duration);
                player.change_speed(app.settings.get_double("playback-speed"));
                detail_wave.position = 0;
            }
            speed_button.label = speed_label(player.speed);
            ((SimpleAction) lookup_action("speed")).set_state(new Variant.double(player.speed));
            sync_transcript();
            update_position();
            var row = row_for(recording);
            if (row != null && !row.get_child_visible()) {
                search.text = "";
            }
            if (row != null && list.get_selected_row() != row) list.select_row(row);
            show_page("detail");
            sync_play();
        }

        private void sync_transcript() {
            if (current == null) return;
            bool has_text = current.transcript != "";
            transcript_label.label = current.transcript;
            transcript_label.get_parent().visible = has_text;
            copy_transcript.visible = has_text;
            transcribe_row.visible = !has_text;
            if (transcribing != null) {
                transcribe_row.subtitle = _("Transcribing on this computer…");
                transcribe_button.sensitive = false;
            } else if (transcriber == null) {
                transcribe_row.subtitle = _("Transcription is not available on this system");
                transcribe_button.sensitive = false;
            } else {
                transcribe_row.subtitle = _("Turn the speech into text on this computer");
                transcribe_button.sensitive = true;
            }
            transcribe_button.visible = transcriber != null;
        }

        private void sync_play() {
            bool playing = player.playing;
            play_button.icon_name = playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
            play_button.tooltip_text = playing ? _("Pause") : _("Play");
        }

        private void toggle_play() {
            if (current == null || recorder.state != RecorderState.IDLE) return;
            player.toggle();
        }

        private void skip(int seconds) {
            int64 target = (player.position() + seconds * NS_PER_SECOND).clamp(0, int64.max(player.duration, 0));
            player.seek(target);
            detail_wave.position = target;
            update_position();
        }

        private void on_speed(SimpleAction action, Variant? value) {
            double speed = value.get_double();
            action.set_state(value);
            player.change_speed(speed);
            app.settings.set_double("playback-speed", speed);
            speed_button.label = speed_label(speed);
        }

        private void start_ticks() {
            if (tick_id != 0) return;
            tick_id = add_tick_callback(() => {
                update_position();
                if (!player.playing) {
                    tick_id = 0;
                    return Source.REMOVE;
                }
                return Source.CONTINUE;
            });
        }

        private void update_position() {
            int64 position = player.position();
            detail_wave.position = position;
            trim_wave.position = stack.visible_child_name == "trim" ? position : 0;
            pos_label.label = Timecode.format(position);
        }

        private void open_trim() {
            if (current == null || recorder.state != RecorderState.IDLE) return;
            player.pause();
            range = new TrimRange(current.duration);
            range.changed.connect(sync_trim);
            trim_wave.duration = current.duration;
            trim_wave.set_peaks(current.peaks);
            trim_wave.range = range;
            trim_mode = TrimMode.KEEP;
            trim_switch.set_active("keep");
            trim_wave.trim_mode = trim_mode;
            trim_progress.visible = false;
            trim_buttons.sensitive = true;
            sync_trim();
            show_page("trim");
            trim_wave.grab_focus();
        }

        private void sync_trim() {
            if (range == null) return;
            trim_span.label = _("%s to %s").printf(Timecode.format(range.start, true), Timecode.format(range.end, true));
            int64 tenth = NS_PER_SECOND / 10;
            int64 shown = range.end / tenth * tenth - range.start / tenth * tenth;
            int64 left = trim_mode == TrimMode.KEEP ? shown : range.duration - shown;
            trim_result.label = range.changes_anything(trim_mode)
                ? _("The recording will be %s long").printf(Timecode.format(left, true))
                : _("Select the part to keep or remove");
            var apply = trim_buttons.get_last_child();
            var copy = apply.get_prev_sibling();
            apply.sensitive = range.changes_anything(trim_mode);
            copy.sensitive = range.changes_anything(trim_mode);
        }

        private void close_trim() {
            player.pause();
            range = null;
            trim_wave.range = null;
            if (current != null) show_recording(current);
            else show_page("welcome");
        }

        public void trim_recording(Recording? recording, int64 start, int64 end, TrimMode mode, bool as_copy) {
            if (recording == null || job != null || recorder.state != RecorderState.IDLE) return;
            var cut = new TrimRange(recording.duration);
            cut.move_end(end);
            cut.move_start(start);
            if (!cut.changes_anything(mode)) return;
            player.close();
            run_trim.begin(recording, cut.kept(mode), as_copy);
        }

        private async void run_trim(Recording recording, owned Span[] keep, bool as_copy) {
            job = new Transcoder();
            sync();
            trim_progress.visible = stack.visible_child_name == "trim";
            trim_progress.fraction = 0;
            trim_buttons.sensitive = false;
            job.progress.connect((f) => trim_progress.fraction = f);
            string file_name;
            string target = library.new_path(out file_name);
            var result = yield job.run(recording.file(library), target, ExportFormat.recording(), keep, recording.duration);
            job = null;
            trim_buttons.sensitive = true;
            trim_progress.visible = false;
            if (result.ok && result.duration <= 0) {
                FileUtils.unlink(target);
                result.ok = false;
                result.error = _("Nothing would be left of the recording");
            }
            if (!result.ok) {
                if (result.error != null) show_error(_("The Recording Could Not Be Trimmed"), result.error);
                show_recording(recording);
                return;
            }
            if (as_copy) {
                var copy = library.add(file_name, _("%s (Trimmed)").printf(recording.title), result.duration, result.peaks);
                range = null;
                show_recording(copy);
                add_toast(new Toast(_("Saved as a new recording")));
                return;
            }
            try {
                library.replace_audio(recording, target, result.duration, result.peaks);
            } catch (Error e) {
                FileUtils.unlink(target);
                show_error(_("The Recording Could Not Be Trimmed"), e.message);
            }
            range = null;
            current = null;
            show_recording(recording);
            add_toast(new Toast(_("Recording trimmed")));
        }

        private void open_export() {
            if (current == null || job != null) return;
            var formats = ExportFormat.available();
            if (formats.length == 0) {
                show_error(_("No Export Formats"), _("No audio encoders are installed on this system."));
                return;
            }
            var dlg = new ConfirmDialog(app, _("Export Recording"), "audio-x-generic", null, _("Export…"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.set_default_size(420, 0);
            var group = new PreferencesGroup(_("File"));
            var list = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            foreach (var format in formats) {
                var option = new Singularity.Core.AppSettingOption();
                option.id = format.id;
                option.label = format.label;
                list.add(option);
            }
            string wanted = app.settings.get_string("export-format");
            if (ExportFormat.find(wanted) == null) wanted = formats[0].id;
            var row = new SelectionRow.with_options(_("Format"), list, wanted);
            group.add_row(row);
            dlg.custom_area.append(group);
            var recording = current;
            dlg.response.connect((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                var format = ExportFormat.find(row.current_value) ?? formats[0];
                app.settings.set_string("export-format", format.id);
                choose_target.begin(recording, format);
            });
            dlg.present();
        }

        private async void choose_target(Recording recording, ExportFormat format) {
            var dialog = new FileDialog();
            dialog.initial_name = "%s.%s".printf(recording.title.replace("/", "-"), format.extension);
            string? music = Environment.get_user_special_dir(UserDirectory.MUSIC);
            if (music == null || !FileUtils.test(music, FileTest.IS_DIR)) music = Environment.get_home_dir();
            dialog.initial_folder = File.new_for_path(music);
            var filter = new FileFilter();
            filter.name = format.label;
            filter.add_mime_type(format.mime);
            var filters = new GLib.ListStore(typeof(FileFilter));
            filters.append(filter);
            dialog.filters = filters;
            try {
                var file = yield dialog.save(this, null);
                if (file != null) export_recording(recording, format, file.get_path());
            } catch (Error e) {
                if (!(e is Gtk.DialogError.DISMISSED)) show_error(_("The Recording Could Not Be Exported"), e.message);
            }
        }

        public void export_recording(Recording? recording, ExportFormat? format, string path) {
            if (recording == null || format == null || job != null) return;
            run_export.begin(recording, format, path);
        }

        private async void run_export(Recording recording, ExportFormat format, string path) {
            job = new Transcoder();
            sync();
            var toast = new Toast(_("Exporting %s…").printf(recording.title));
            toast.timeout = 0;
            toast.button_label = _("Cancel");
            var running = job;
            toast.button_clicked.connect(() => running.cancel());
            add_toast(toast);
            var result = yield job.run(recording.file(library), path, format, {}, recording.duration);
            job = null;
            toast.dismiss();
            sync();
            if (result.ok) {
                var done = new Toast(_("Exported %s").printf(Path.get_basename(path)));
                done.button_label = _("Show in Files");
                done.button_clicked.connect(() => reveal_file(File.new_for_path(path)));
                add_toast(done);
            } else if (result.error != null) {
                show_error(_("The Recording Could Not Be Exported"), result.error);
            }
        }

        private void share(Recording? recording) {
            if (recording == null) return;
            string dir = Path.build_filename(Environment.get_user_cache_dir(), "dev.sinty.voice", "share");
            DirUtils.create_with_parents(dir, 0700);
            var source = recording.file(library);
            var target = File.new_for_path(Path.build_filename(dir, "%s.ogg".printf(recording.title.replace("/", "-"))));
            try {
                source.copy(target, FileCopyFlags.OVERWRITE);
                Singularity.Share.files(this, { target });
            } catch (Error e) {
                Singularity.Share.files(this, { source });
            }
        }

        private void show_in_files(Recording? recording) {
            if (recording == null) return;
            reveal_file(recording.file(library));
        }

        private void reveal_file(File file) {
            var launcher = new FileLauncher(file);
            launcher.open_containing_folder.begin(this, null, (obj, res) => {
                try {
                    launcher.open_containing_folder.end(res);
                } catch (Error e) {
                    if (!(e is Gtk.DialogError.DISMISSED)) show_error(_("The Folder Could Not Be Opened"), e.message);
                }
            });
        }

        private void open_rename(Recording? recording) {
            if (recording == null) return;
            var dlg = new ConfirmDialog(app, _("Rename Recording"), "audio-x-generic", null, _("Rename"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.set_default_size(420, 0);
            var group = new PreferencesGroup();
            var entry = new EntryRow(_("Name"));
            entry.text = recording.title;
            group.add_row(entry);
            dlg.custom_area.append(group);
            dlg.response.connect((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                library.rename(recording, entry.text);
                if (current == recording) detail_title.label = recording.title;
            });
            entry.entry_activated.connect(() => {
                library.rename(recording, entry.text);
                if (current == recording) detail_title.label = recording.title;
                dlg.close_dialog();
            });
            dlg.present();
            entry.grab_focus();
        }

        private void confirm_delete(Recording? recording) {
            if (recording == null) return;
            var dlg = new ConfirmDialog(app, _("Delete “%s”?").printf(recording.title), "user-trash-symbolic",
                _("The recording is moved to the trash."), _("Delete"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                if (current != recording) {
                    library.remove(recording);
                    return;
                }
                int index = library.items.index_of(recording);
                player.close();
                current = null;
                library.remove(recording);
                if (library.items.size > 0) show_recording(library.items[int.min(index, library.items.size - 1)]);
                else show_page("welcome");
            });
            dlg.present();
        }

        private void relocate_transcriber(DBusConnection connection) {
            transcriber = Transcript.locate(connection);
            sync();
            if (current != null) sync_transcript();
        }

        private async void transcribe() {
            if (current == null || transcriber == null || transcribing != null) return;
            var backend = transcriber;
            var recording = current;
            transcribing = new Cancellable();
            sync();
            sync_transcript();
            string dir = Path.build_filename(Environment.get_user_cache_dir(), "dev.sinty.voice");
            DirUtils.create_with_parents(dir, 0700);
            string wav = Path.build_filename(dir, "speech-%s.wav".printf(recording.id));
            var convert = new Transcoder();
            var result = yield convert.run(recording.file(library), wav, ExportFormat.speech(), {}, recording.duration);
            string? error = result.ok ? null : (result.error ?? _("The recording could not be read"));
            if (result.ok) {
                try {
                    string language = app.settings.get_string("transcription-language");
                    string text = yield backend.transcribe(wav, language, transcribing);
                    recording.transcript = text != "" ? text : _("No speech was recognized.");
                    library.save();
                } catch (Error e) {
                    error = e.message;
                }
            }
            FileUtils.unlink(wav);
            transcribing = null;
            sync();
            if (current == recording) sync_transcript();
            if (error != null) show_error(_("The Recording Could Not Be Transcribed"), error);
        }

        private void show_error(string title, string message) {
            var dlg = new ConfirmDialog.message(app, title, "dialog-error-symbolic", message);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.present();
        }
    }
}
