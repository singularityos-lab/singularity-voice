namespace Singularity.Apps.Voice {

    [CCode (cname = "VOICE_SYSCONFDIR")]
    extern const string SYSCONFDIR;

    public abstract class TranscriptionBackend : Object {
        public abstract string name { get; }
        public abstract async string transcribe(string wav_path, string language, Cancellable? cancellable) throws Error;
    }

    public class DictationBusBackend : TranscriptionBackend {
        public const string BUS_NAME = "dev.sinty.Dictation";
        public const string OBJECT_PATH = "/dev/sinty/Dictation";
        public const string INTERFACE = "dev.sinty.Dictation";

        public override string name { get { return "dictation"; } }

        private DBusConnection connection;

        public DictationBusBackend(DBusConnection connection) {
            this.connection = connection;
        }

        public static bool present(DBusConnection connection) {
            foreach (string method in new string[] { "NameHasOwner", "ListActivatableNames" }) {
                try {
                    var reply = connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                        method, method == "NameHasOwner" ? new Variant("(s)", BUS_NAME) : null,
                        null, DBusCallFlags.NONE, 2000, null);
                    if (method == "NameHasOwner") {
                        bool owned;
                        reply.get("(b)", out owned);
                        if (owned) return true;
                    } else {
                        var names = reply.get_child_value(0);
                        for (size_t i = 0; i < names.n_children(); i++) {
                            if (names.get_child_value(i).get_string() == BUS_NAME) return true;
                        }
                    }
                } catch (Error e) {
                }
            }
            return false;
        }

        public override async string transcribe(string wav_path, string language, Cancellable? cancellable) throws Error {
            Variant reply;
            try {
                reply = yield connection.call(BUS_NAME, OBJECT_PATH, INTERFACE, "TranscribeFile",
                    new Variant("(ss)", wav_path, language), new VariantType("(s)"), DBusCallFlags.NONE, 30 * 60 * 1000, cancellable);
            } catch (Error e) {
                DBusError.strip_remote_error(e);
                throw e;
            }
            string text;
            reply.get("(s)", out text);
            return text.strip();
        }
    }

    public class CommandBackend : TranscriptionBackend {
        public override string name { get { return "command"; } }
        public string[] argv { get; construct; }

        public CommandBackend(string[] argv) {
            Object(argv: argv);
        }

        public static string? config_path() {
            string[] dirs = { Environment.get_user_config_dir() };
            foreach (string dir in Environment.get_system_config_dirs()) dirs += dir;
            dirs += SYSCONFDIR;
            foreach (string dir in dirs) {
                string path = Path.build_filename(dir, "singularity", "recorder.conf");
                if (FileUtils.test(path, FileTest.IS_REGULAR)) return path;
            }
            return null;
        }

        public static CommandBackend? from_config() {
            string? path = config_path();
            if (path == null) return null;
            try {
                var file = new KeyFile();
                file.load_from_file(path, KeyFileFlags.NONE);
                if (!file.has_key("Transcription", "Command")) return null;
                string[] argv;
                GLib.Shell.parse_argv(file.get_string("Transcription", "Command"), out argv);
                if (argv.length == 0) return null;
                return new CommandBackend(argv);
            } catch (Error e) {
                warning("Recorder: cannot read %s: %s", path, e.message);
                return null;
            }
        }

        public override async string transcribe(string wav_path, string language, Cancellable? cancellable) throws Error {
            string[] command = {};
            foreach (string arg in argv) command += arg.replace("%f", wav_path).replace("%l", language == "" ? "auto" : language);
            var process = new Subprocess.newv(command, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            string? output = null;
            yield process.communicate_utf8_async(null, cancellable, out output, null);
            if (!process.get_successful()) throw new IOError.FAILED(_("The speech engine stopped unexpectedly"));
            return TranscriptText.clean(output ?? "");
        }
    }

    namespace Transcript {
        public TranscriptionBackend? locate(DBusConnection? connection) {
            if (connection != null && DictationBusBackend.present(connection)) return new DictationBusBackend(connection);
            return CommandBackend.from_config();
        }
    }
}
