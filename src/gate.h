#pragma once
#include <gst/gst.h>

typedef struct _VoiceGate VoiceGate;

VoiceGate *voice_gate_new (GstPad *pad);
void voice_gate_set_paused (VoiceGate *gate, gboolean paused);
void voice_gate_add_offset (VoiceGate *gate, gint64 offset);
void voice_gate_free (VoiceGate *gate);
