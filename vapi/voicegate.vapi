[CCode (cheader_filename = "gate.h")]
namespace VoiceGateC {
    [Compact]
    [CCode (cname = "VoiceGate", free_function = "voice_gate_free")]
    public class Gate {
        [CCode (cname = "voice_gate_new")]
        public Gate (Gst.Pad pad);
        [CCode (cname = "voice_gate_set_paused")]
        public void set_paused (bool paused);
        [CCode (cname = "voice_gate_add_offset")]
        public void add_offset (int64 offset);
    }
}
