    /*
     * How long a failed initialisation stays on screen. A constant, because
     * it is not a caller's decision: the box has to be readable by a person
     * who is there and finite for a machine that is not, and no environment
     * gets to make it either zero or forever.
     */
    NeutrinoWebview.windowsErrorSeconds = 20;

    /*
     * A failed initialisation, said in both places it can be heard.
     *
     * This was MessageBox.Show and then Environment.Exit, and the box never
     * returns. Measured on a runner with nobody at it, in three shapes in
     * one step: detached -- which is the only way `START "" ... .exe` ever
     * launches this -- and with both handles redirected, the process was
     * still up holding its window when the probe gave up; and the shipped
     * driver did the same for ninety seconds after a real download threw.
     * Nobody clicks it, so the run ends on somebody's timeout rather than
     * on the error, and the error itself is never said anywhere.
     *
     * Two obvious alternatives were measured not to work.
     * Environment.UserInteractive reads true on an unattended runner, so it
     * cannot tell a machine from a person. And a /t:winexe process launched
     * detached gets NullStream for Console.Out and Console.Error both, so
     * writing the error out reaches nobody unless the caller happened to
     * hand it handles -- which the .cmd, which uses START, does not.
     *
     * So: a box that lets go by itself, and a file that stays.
     */
    NeutrinoWebview.showWindowsError = function (SystemRef, title, message) {
        var written = this.recordWindowsError(SystemRef, title, message);
        var shown = String(message);
        if (written) {
            shown = shown + "\n\n" + written;
        }
        this.showBoundedError(SystemRef, title, shown);
    };

    /*
     * The failure, written where it outlives the process. Measured: after a
     * real failed initialisation the app folder held the exe, its manifest
     * and the build stamp, and nothing at all that named what went wrong --
     * so a machine that hit this had no way to find out why, then or later.
     *
     * Best effort by construction, and the return value says whether it
     * worked so the box can name the file when there is one. If this throws
     * there is nowhere left to say so, and the box is still worth putting up.
     */
    /*
     * Where to write a failure down when the failure may be that there is
     * no layout. windowsLayout throws when the document cannot be found,
     * and that is the one refusal most worth recording -- so this does not
     * get to depend on it. Both layouts put the app folder either beside
     * this program or at it, and an existing <exe dir>\<name> tells them
     * apart without asking where the document is.
     */
    NeutrinoWebview.windowsErrorFolder = function (SystemRef) {
        try {
            return this.windowsLayout(SystemRef).appFolder;
        } catch (_) {
        }
        var exe = SystemRef.Windows.Forms.Application.ExecutablePath;
        var exeDir = SystemRef.IO.Path.GetDirectoryName(exe);
        var name = SystemRef.IO.Path.GetFileNameWithoutExtension(exe);
        var beside = SystemRef.IO.Path.Combine(exeDir, name);
        if (SystemRef.IO.Directory.Exists(beside)) {
            return beside;
        }
        return exeDir;
    };

    NeutrinoWebview.recordWindowsError = function (SystemRef, title, message) {
        var written = "";
        try {
            var path = SystemRef.IO.Path.Combine(
                this.windowsErrorFolder(SystemRef),
                "neutrino-error.log"
            );
            SystemRef.IO.File.WriteAllText(
                path,
                String(title) + "\r\n" +
                SystemRef.DateTime.UtcNow.ToString("u") + "\r\n\r\n" +
                String(message) + "\r\n"
            );
            written = path;
        } catch (_) {
        }
        /*
         * Free when a caller did hand this process handles, and silently
         * nothing when it did not -- which is why the file above exists and
         * this is not the whole story. Measured both ways.
         */
        try {
            SystemRef.Console.Error.WriteLine(String(title) + ": " + String(message));
            if (written) {
                SystemRef.Console.Error.WriteLine("neutrino: written to " + written);
            }
            SystemRef.Console.Error.Flush();
        } catch (_) {
        }
        return written;
    };

    /*
     * The same box, driven by the loop this driver already runs on rather
     * than by one it cannot reach into. runEventLoop is Show() and then
     * DoEvents()/Sleep() while the window is visible; the download progress
     * form is the same; this is that with a deadline in the condition. A
     * person closing it ends the loop early, and nobody closing it ends the
     * loop anyway.
     *
     * Measured detached, with nobody at the machine: the window was on
     * screen for the whole deadline and the process was gone afterwards --
     * in the same step, on the same binary, where MessageBox.Show was still
     * up holding a window. That the window was actually painted is half the
     * measurement: a box that disposes itself before it is shown ends just
     * as promptly and is no use to the person it is for.
     */
    NeutrinoWebview.showBoundedError = function (SystemRef, title, message) {
        try {
            var form = new SystemRef.Windows.Forms.Form();
            form.Text = String(title);
            form.FormBorderStyle = SystemRef.Windows.Forms.FormBorderStyle.FixedDialog;
            form.StartPosition = SystemRef.Windows.Forms.FormStartPosition.CenterScreen;
            form.ClientSize = new SystemRef.Drawing.Size(440, 148);
            form.MinimizeBox = false;
            form.MaximizeBox = false;
            form.TopMost = true;

            var label = new SystemRef.Windows.Forms.Label();
            label.AutoSize = false;
            label.TextAlign = SystemRef.Drawing.ContentAlignment.TopLeft;
            label.SetBounds(16, 12, 408, 120);
            label.Text = String(message);
            form.Controls.Add(label);

            form.Show();
            form.Refresh();
            SystemRef.Windows.Forms.Application.DoEvents();

            /*
             * Ticks rather than DateTimes, so the comparison is an int
             * comparison. TickCount wraps every 24.9 days; the subtraction
             * is what keeps a wrap from either ending the box immediately or
             * never ending it.
             */
            var start = SystemRef.Environment.TickCount;
            var budget = this.windowsErrorSeconds * 1000;
            while (form.Visible && (SystemRef.Environment.TickCount - start) < budget) {
                SystemRef.Windows.Forms.Application.DoEvents();
                SystemRef.Threading.Thread.Sleep(16);
            }
            form.Close();
        } catch (_) {
        }
    };

