/* WPS loads this file in its add-in host. No network calls or keyboard hooks. */
function cpaHandleRequest(app, request, now) {
    var answer = { id: request.id, pid: request.pid, phase: request.phase, eligible: false };
    if (typeof request.id !== 'string' || !request.id || typeof request.createdAt !== 'number'
        || !isFinite(request.createdAt) || Math.abs(now - request.createdAt) > 1000) return answer;
    if (request.phase !== 'metadata' && request.phase !== 'body') return answer;
    var doc = app.ActiveDocument, selection = app.Selection;
    if (!doc || !selection || doc.ReadOnly !== false || doc.ProtectionType !== -1
        || selection.Type !== 1 || selection.Range.StoryType !== 1) return answer;
    var range = doc.Content;
    if (range.End - range.Start > 2001) return answer;
    var documentId = String(doc.FullName);
    if (request.documentId && request.documentId !== documentId) return answer;
    answer.documentId = documentId;
    answer.eligible = true;
    if (request.phase === 'body') {
        // Text is read only after the helper's policy-approved body request.
        var text = String(range.Text);
        if (text.slice(-1) === '\r') text = text.slice(0, -1);
        var cursor = selection.Start - range.Start;
        if (cursor < 0 || cursor > text.length || text.length > 2000) {
            answer.eligible = false;
            return answer;
        }
        answer.text = text;
        answer.cursor = cursor;
    }
    return answer;
}
var cpaTimer = null;
function OnAddinLoad() {
    var app = wps.WpsApplication ? wps.WpsApplication() : wps.Application;
    var fs = app.FileSystem, lastId = null, lastReady = 0, responseExpires = 0;
    if (cpaTimer) clearInterval(cpaTimer);
    cpaTimer = setInterval(function () {
        try {
            var now = Date.now();
            if (responseExpires && now >= responseExpires) {
                // Overwrite the private mailbox even if the helper stopped before consuming it.
                fs.writeFileString(CPA_BRIDGE_PATH + '/response.json', '{}');
                responseExpires = 0;
            }
            if (now - lastReady > 500) {
                fs.writeFileString(CPA_BRIDGE_PATH + '/ready.json', JSON.stringify({version:1, time:now}));
                lastReady = now;
            }
            var raw = fs.readFileString(CPA_BRIDGE_PATH + '/request.json');
            if (!raw || raw.length > 8192) return;
            var request = JSON.parse(raw);
            if (request.id === lastId) return;
            lastId = request.id;
            var response = cpaHandleRequest(app, request, now);
            fs.writeFileString(CPA_BRIDGE_PATH + '/response.json', JSON.stringify(response));
            responseExpires = now + 1000;
        } catch (_) {
            // No document, unsupported API, or a file being atomically replaced: fail closed.
        }
    }, 75);
    return true;
}
if (typeof module !== 'undefined') module.exports = { cpaHandleRequest: cpaHandleRequest };
