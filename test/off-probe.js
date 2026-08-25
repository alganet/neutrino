// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// Served to test/neutrinooffline.js by the probe's own target server. Every
// subresource shape it tries points at a file that really is there, so a page
// reading ERR is reading a policy decision and not a 404 -- the request log
// records the attempt either way, but the page's own half of the reading is
// only worth having if a permitted load succeeds.
window.__neutrinoOffProbeScript = 1;
