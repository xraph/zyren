#define MA_NO_NULL
#define MA_NO_ENCODING
#define MA_NO_DECODING
#define MA_NO_RESOURCE_MANAGER
#define MINIAUDIO_IMPLEMENTATION
#include "vendor/miniaudio.h"
#include <stdlib.h>

#if defined(_WIN32)
#define ZA_API __declspec(dllexport)
#else
#define ZA_API __attribute__((visibility("default")))
#endif

typedef struct za_voice {
    ma_sound sound;
    ma_audio_buffer buffer;
    struct za_voice *next;
} za_voice;
typedef struct {
    ma_engine engine;
    za_voice *voices;
    int offline;
} za_engine;

ZA_API int za_engine_create(int offline, unsigned int rate, za_engine **out) {
    *out = NULL;
    za_engine *value = calloc(1, sizeof(*value));
    if (!value) return MA_OUT_OF_MEMORY;
    ma_engine_config config = ma_engine_config_init();
    config.noDevice = offline;
    config.channels = 2;
    config.sampleRate = rate;
    ma_result result = ma_engine_init(&config, &value->engine);
    if (result != MA_SUCCESS) { free(value); return result; }
    value->offline = offline;
    *out = value;
    return MA_SUCCESS;
}

ZA_API void za_voice_free(za_engine *engine, za_voice *voice) {
    za_voice **cursor = &engine->voices;
    while (*cursor && *cursor != voice) cursor = &(*cursor)->next;
    if (!*cursor) return;
    *cursor = voice->next;
    ma_sound_uninit(&voice->sound);
    ma_audio_buffer_uninit(&voice->buffer);
    free(voice);
}

ZA_API void za_engine_free(za_engine *value) {
    if (!value) return;
    while (value->voices) za_voice_free(value, value->voices);
    ma_engine_uninit(&value->engine);
    free(value);
}

ZA_API const char *za_backend_name(za_engine *value) {
    if (value->offline) return "miniaudio-offline";
    return ma_get_backend_name(ma_engine_get_device(&value->engine)->pContext->backend);
}

ZA_API int za_voice_create(za_engine *engine, const float *pcm, unsigned int frames,
                           za_voice **out) {
    *out = NULL;
    za_voice *voice = calloc(1, sizeof(*voice));
    if (!voice) return MA_OUT_OF_MEMORY;
    ma_audio_buffer_config config = ma_audio_buffer_config_init(ma_format_f32, 1, frames, pcm, NULL);
    config.sampleRate = ma_engine_get_sample_rate(&engine->engine);
    ma_result result = ma_audio_buffer_init_copy(&config, &voice->buffer);
    if (result != MA_SUCCESS) { free(voice); return result; }
    result = ma_sound_init_from_data_source(&engine->engine, &voice->buffer, 0, NULL, &voice->sound);
    if (result != MA_SUCCESS) {
        ma_audio_buffer_uninit(&voice->buffer); free(voice); return result;
    }
    ma_sound_set_pinned_listener_index(&voice->sound, 0);
    ma_sound_set_doppler_factor(&voice->sound, 0);
    voice->next = engine->voices;
    engine->voices = voice;
    *out = voice;
    return MA_SUCCESS;
}

ZA_API void za_listener(za_engine *engine, float x, float y, float z,
                       float fx, float fy, float fz, float ux, float uy, float uz) {
    ma_engine_listener_set_position(&engine->engine, 0, x, y, z);
    ma_engine_listener_set_direction(&engine->engine, 0, fx, fy, fz);
    ma_engine_listener_set_world_up(&engine->engine, 0, ux, uy, uz);
}
ZA_API void za_position(za_voice *voice, float x, float y, float z) {
    ma_sound_set_position(&voice->sound, x, y, z);
}
ZA_API void za_settings(za_voice *voice, float volume, float min_distance,
                       float max_distance, float rolloff, int attenuation, int loop) {
    ma_sound_set_volume(&voice->sound, volume);
    ma_sound_set_min_distance(&voice->sound, min_distance);
    ma_sound_set_max_distance(&voice->sound, max_distance);
    ma_sound_set_rolloff(&voice->sound, rolloff);
    ma_sound_set_attenuation_model(&voice->sound, attenuation);
    ma_sound_set_looping(&voice->sound, loop);
}
ZA_API int za_play(za_voice *voice) { return ma_sound_start(&voice->sound); }
ZA_API int za_pause(za_voice *voice) { return ma_sound_stop(&voice->sound); }
ZA_API int za_rewind(za_voice *voice) { return ma_sound_seek_to_pcm_frame(&voice->sound, 0); }
ZA_API int za_playing(za_voice *voice) { return ma_sound_is_playing(&voice->sound); }
ZA_API int za_read(za_engine *engine, float *out, unsigned int frames) {
    if (!engine->offline) return MA_INVALID_OPERATION;
    return ma_engine_read_pcm_frames(&engine->engine, out, frames, NULL);
}
