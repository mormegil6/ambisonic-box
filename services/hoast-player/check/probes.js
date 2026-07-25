// Browser capability probes for multichannel Opus, shared by the standalone
// /check/ page and the player's ?dbg output. Deliberately independent of the
// player, the stack and any live stream: the assets are tiny static files, so
// the codec question gets an answer even when everything else is down or
// broken (WebGL, DeviceOrientation, MSE, the box being idle).
//
// decodeAudioData runs on an OfflineAudioContext: it needs no user gesture
// and no autoplay permission, so the page can probe on load with one tap.
//
// runCapabilityProbes(basePath) -> Promise<{results, text}> where results is
// structured and text is a paste-friendly plain report.
function runCapabilityProbes(basePath) {
    'use strict';
    basePath = basePath || '/check/';
    var results = { ua: navigator.userAgent, probes: {} };

    function withTimeout(p, ms, what) {
        return Promise.race([p, new Promise(function (_, rej) {
            setTimeout(function () { rej(new Error(what + ' timed out after ' + ms / 1000 + ' s')); }, ms);
        })]);
    }

    function decodeProbe(label, file) {
        return withTimeout(fetch(basePath + file, { cache: 'no-store' })
            .then(function (r) {
                if (!r.ok) throw new Error('asset fetch failed: HTTP ' + r.status);
                return r.arrayBuffer();
            })
            .then(function (buf) {
                // 1x1 render quantum; only decodeAudioData matters here
                var Ctx = window.OfflineAudioContext || window.webkitOfflineAudioContext;
                if (!Ctx) throw new Error('no OfflineAudioContext');
                var ctx = new Ctx(1, 1, 48000);
                return new Promise(function (res, rej) {
                    // callback form: Safari's promise form was late to arrive
                    ctx.decodeAudioData(buf, res, function (e) {
                        rej(e instanceof Error ? e : new Error(e && e.message ? e.message : 'decode failed (no error detail)'));
                    });
                });
            })
            , 8000, 'decode of ' + file)
            .then(function (audio) {
                results.probes[label] = {
                    ok: true,
                    channels: audio.numberOfChannels,
                    sampleRate: audio.sampleRate,
                    duration: Math.round(audio.duration * 100) / 100
                };
            })
            .catch(function (e) {
                results.probes[label] = { ok: false, error: String(e && e.message ? e.message : e) };
            });
    }

    // MSE / MMS / output-channel facts (synchronous)
    function collectStatics() {
        var mse = window.MediaSource, mms = window.ManagedMediaSource;
        function its(kind, type) {
            try { return kind ? !!kind.isTypeSupported(type) : false; }
            catch (e) { return 'threw: ' + e.message; }
        }
        results.probes.mse = {
            present: !!mse,
            webmOpus: its(mse, 'audio/webm; codecs="opus"'),
            mp4Opus: its(mse, 'audio/mp4; codecs="opus"')
        };
        results.probes.managedMediaSource = {
            present: !!mms,
            webmOpus: mms ? its(mms, 'audio/webm; codecs="opus"') : false,
            mp4Opus: mms ? its(mms, 'audio/mp4; codecs="opus"') : false
        };
        try {
            var AC = window.AudioContext || window.webkitAudioContext;
            var ac = new AC();
            results.probes.maxChannelCount = ac.destination.maxChannelCount;
            if (ac.close) ac.close();
        } catch (e) {
            results.probes.maxChannelCount = 'unavailable: ' + e.message;
        }
    }

    function toText() {
        var p = results.probes, lines = [];
        function dec(label, name) {
            var d = p[label];
            if (!d) return name + ': not run';
            return d.ok
                ? name + ': DECODED (' + d.channels + ' ch, ' + d.sampleRate + ' Hz, ' + d.duration + ' s)'
                : name + ': FAILED (' + d.error + ')';
        }
        lines.push('capability check ' + new Date().toISOString());
        lines.push(dec('opus2', 'stereo Opus control (WebM)'));
        lines.push(dec('opus16', '16-channel (3OA) Opus (WebM)'));
        lines.push(dec('opus25', '25-channel (4OA) Opus (WebM)'));
        lines.push('MSE present: ' + p.mse.present
            + ' | audio/webm opus: ' + p.mse.webmOpus
            + ' | audio/mp4 opus: ' + p.mse.mp4Opus);
        lines.push('ManagedMediaSource present: ' + p.managedMediaSource.present
            + (p.managedMediaSource.present
                ? ' | audio/webm opus: ' + p.managedMediaSource.webmOpus
                  + ' | audio/mp4 opus: ' + p.managedMediaSource.mp4Opus
                : ''));
        lines.push('AudioContext maxChannelCount: ' + p.maxChannelCount);
        lines.push('userAgent: ' + results.ua);
        return lines.join('\n');
    }

    collectStatics();
    return decodeProbe('opus2', 'opus-2ch.webm')
        .then(function () { return decodeProbe('opus16', 'opus-16ch.webm'); })
        .then(function () { return decodeProbe('opus25', 'opus-25ch.webm'); })
        .then(function () { return { results: results, text: toText() }; });
}
