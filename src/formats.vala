namespace Singularity.Apps.Voice {

    public class ExportFormat : Object {
        public string id { get; construct; }
        public string label { get; construct; }
        public string extension { get; construct; }
        public string mime { get; construct; }
        public string chain { get; construct; }

        public ExportFormat(string id, string label, string extension, string mime, string chain) {
            Object(id: id, label: label, extension: extension, mime: mime, chain: chain);
        }

        private static ExportFormat[]? cached = null;

        private static bool has(string element) {
            return Gst.ElementFactory.find(element) != null;
        }

        private static string? first(string[] elements) {
            foreach (string element in elements) {
                if (has(element)) return element;
            }
            return null;
        }

        public static ExportFormat[] available() {
            if (cached != null) return cached;
            ExportFormat[] list = {};
            if (has("opusenc") && has("oggmux")) {
                list += new ExportFormat("opus", _("Opus"), "ogg", "audio/ogg",
                    "audioconvert ! audioresample ! opusenc bitrate=96000 ! oggmux");
            }
            string? aac = first({ "fdkaacenc", "avenc_aac", "voaacenc", "faac" });
            if (aac != null && has("mp4mux")) {
                list += new ExportFormat("m4a", _("AAC (M4A)"), "m4a", "audio/mp4",
                    "audioconvert ! audioresample ! %s bitrate=128000 ! mp4mux".printf(aac));
            }
            if (has("lamemp3enc")) {
                list += new ExportFormat("mp3", _("MP3"), "mp3", "audio/mpeg",
                    "audioconvert ! audioresample ! lamemp3enc target=bitrate bitrate=192 cbr=true" + (has("id3v2mux") ? " ! id3v2mux" : ""));
            }
            if (has("flacenc")) {
                list += new ExportFormat("flac", _("FLAC"), "flac", "audio/flac",
                    "audioconvert ! flacenc");
            }
            if (has("wavenc")) {
                list += new ExportFormat("wav", _("WAV"), "wav", "audio/wav",
                    "audioconvert ! wavenc");
            }
            cached = list;
            return list;
        }

        public static ExportFormat? find(string id) {
            foreach (var format in available()) {
                if (format.id == id) return format;
            }
            return null;
        }

        public static ExportFormat recording() {
            return new ExportFormat("opus", _("Opus"), "ogg", "audio/ogg",
                "audioconvert ! audioresample ! opusenc bitrate=64000 ! oggmux");
        }

        public static ExportFormat speech() {
            return new ExportFormat("speech", "WAV 16 kHz", "wav", "audio/wav",
                "audioconvert ! audioresample ! audio/x-raw,format=S16LE,rate=16000,channels=1 ! wavenc");
        }
    }
}
