%% mob_whisper_nif — whisper.cpp transcription + microphone capture.
%%
%% Native side: c_src/mob_whisper_nif.cpp (a cpp_archive NIF, see
%% priv/mob_plugin.exs) statically linked into the host app on device. On a
%% host dev build nothing is linked, so on_load tolerates the failure and every
%% function raises nif_not_loaded except nif_loaded/0, which returns false.
%%
%% transcribe/5 returns {ok, Ref, JobId} at once; the caller later receives
%% {mob_whisper_result, Ref, {ok, Text} | {error, Reason}}. abort/2 cancels
%% that job.
-module(mob_whisper_nif).
-export([nif_loaded/0, load_model/1, transcribe/5, abort/2, capture_start/0, capture_stop/0]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_whisper_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

nif_loaded() ->
    false.

load_model(_Path) ->
    erlang:nif_error(nif_not_loaded).

transcribe(_Model, _Pcm, _Language, _Threads, _AudioCtx) ->
    erlang:nif_error(nif_not_loaded).

abort(_Model, _JobId) ->
    erlang:nif_error(nif_not_loaded).

capture_start() ->
    erlang:nif_error(nif_not_loaded).

capture_stop() ->
    erlang:nif_error(nif_not_loaded).
