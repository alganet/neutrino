if (":" == "<!--") then : 0 /*\;:\
@ECHO OFF||:;fi;:||REM<<'EXIT'
GOTO :W
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
SPDX-License-Identifier: ISC
:W
@@include cmd/launcher.cmd
EXIT
@@include sh/parts.list
exit $?;:<<'//</script></body></html>' #-->
@@include html/document.html
<script type=text/javascript>//*/

    /*@cc_on
        @if (@_jscript_version >= 7)
@@include jsc/parts.list
        @end
    @*/

@@include js/parts.list
//</script></body></html>
