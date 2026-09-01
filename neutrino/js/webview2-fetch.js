    NeutrinoWebview.downloadWebView2WithProgress = function (SystemRef, appFolder) {
        var packageRoot = SystemRef.IO.Path.Combine(appFolder, "Microsoft.Web.WebView2");
        var tempPackagePath = SystemRef.IO.Path.Combine(
            SystemRef.IO.Path.GetTempPath(),
            "Microsoft.Web.WebView2." + SystemRef.Guid.NewGuid().ToString("N") + ".zip"
        );
        var packageUrl = this.webView2PackageUrl();

        var progressForm = new SystemRef.Windows.Forms.Form();
        progressForm.Text = "Downloading WebView2 Runtime";
        progressForm.FormBorderStyle = SystemRef.Windows.Forms.FormBorderStyle.FixedDialog;
        progressForm.StartPosition = SystemRef.Windows.Forms.FormStartPosition.CenterScreen;
        progressForm.ClientSize = new SystemRef.Drawing.Size(440, 92);
        progressForm.ControlBox = false;
        progressForm.TopMost = true;

        var progressLabel = new SystemRef.Windows.Forms.Label();
        progressLabel.AutoSize = false;
        progressLabel.TextAlign = SystemRef.Drawing.ContentAlignment.MiddleLeft;
        progressLabel.SetBounds(16, 12, 408, 20);
        progressLabel.Text = "Starting download...";

        var progressBar = new SystemRef.Windows.Forms.ProgressBar();
        progressBar.SetBounds(16, 40, 408, 22);
        progressBar.Minimum = 0;
        progressBar.Maximum = 100;
        progressBar.Style = SystemRef.Windows.Forms.ProgressBarStyle.Continuous;

        progressForm.Controls.Add(progressLabel);
        progressForm.Controls.Add(progressBar);
        progressForm.Show();
        progressForm.Refresh();
        SystemRef.Windows.Forms.Application.DoEvents();

        var response = null;
        var responseStream = null;
        var fileStream = null;

        try {
            if (SystemRef.IO.Directory.Exists(packageRoot)) {
                this.deleteTree(SystemRef, packageRoot);
            }

            /*
             * TLS 1.0 and 1.1 were enabled here alongside 1.2. Turning a
             * protocol on does not make a server offer it, but it does mean
             * this client would accept one that did, which is the whole
             * point of a downgrade. nuget.org has not spoken either of them
             * for years. 1.3 is set where the framework knows the value and
             * ignored where it does not.
             */
            try {
                var tls12 = 3072;
                var tls13 = 12288;
                SystemRef.Net.ServicePointManager.SecurityProtocol = tls12 | tls13;
            } catch (_) {
                try {
                    SystemRef.Net.ServicePointManager.SecurityProtocol = 3072;
                } catch (_) {
                }
            }

            var request = SystemRef.Net.WebRequest.Create(packageUrl);
            response = request.GetResponse();
            responseStream = response.GetResponseStream();

            var totalBytes = response.ContentLength;
            if (totalBytes <= 0) {
                progressBar.Style = SystemRef.Windows.Forms.ProgressBarStyle.Marquee;
                progressLabel.Text = "Downloading package...";
            }

            fileStream = new SystemRef.IO.FileStream(tempPackagePath, SystemRef.IO.FileMode.Create, SystemRef.IO.FileAccess.Write, SystemRef.IO.FileShare.None);
            var buffer = System.Array.CreateInstance(System.Byte, 32768);
            var downloadedBytes = 0;
            var lastPercentage = -1;
            var bytesRead = 0;

            while ((bytesRead = responseStream.Read(buffer, 0, buffer.Length)) > 0) {
                fileStream.Write(buffer, 0, bytesRead);
                downloadedBytes += bytesRead;

                if (totalBytes > 0) {
                    var percentage = System.Math.Min(100, System.Convert.ToInt32((downloadedBytes * 100.0) / totalBytes));
                    if (percentage !== lastPercentage) {
                        progressBar.Value = percentage;
                        progressLabel.Text = "Downloading package... " + percentage + "%";
                        lastPercentage = percentage;
                    }
                }

                SystemRef.Windows.Forms.Application.DoEvents();
            }

            fileStream.Close();
            fileStream = null;
            responseStream.Close();
            responseStream = null;
            response.Close();
            response = null;

            if (totalBytes > 0) {
                progressBar.Value = 100;
            }
            progressLabel.Text = "Verifying package...";
            SystemRef.Windows.Forms.Application.DoEvents();

            /*
             * Before anything is taken out of it, and before anything is
             * written where the app will later load code from. A mismatch
             * is fatal rather than a fallback: there is no weaker thing to
             * fall back to that is still this app.
             */
            var digest = this.sha256Hex(SystemRef, tempPackagePath);
            if (digest !== this.webView2PinnedSha256) {
                throw new Error("WebView2 package does not match its pin.\n\nexpected " +
                    this.webView2PinnedSha256 + "\ngot      " + digest);
            }

            progressLabel.Text = "Extracting package...";
            SystemRef.Windows.Forms.Application.DoEvents();

            this.extractWebView2Members(SystemRef, tempPackagePath, packageRoot);
        } catch (exDownload) {
            var message = "Download/extract failed.";
            try {
                if (exDownload && exDownload.message) {
                    message = message + "\n\n" + String(exDownload.message);
                }
            } catch (_) {
            }
            try {
                message = message + "\n\n" + String(exDownload);
            } catch (_) {
            }
            throw new Error(message);
        } finally {
            if (fileStream) {
                fileStream.Close();
            }
            if (responseStream) {
                responseStream.Close();
            }
            if (response) {
                response.Close();
            }
            if (SystemRef.IO.File.Exists(tempPackagePath)) {
                SystemRef.IO.File.Delete(tempPackagePath);
            }
            progressForm.Close();
            progressForm.Dispose();
        }
    };

    NeutrinoWebview.webView2PackageRootOf = function (SystemRef, libDir) {
        return SystemRef.IO.Path.GetFullPath(SystemRef.IO.Path.Combine(libDir, "..", ".."));
    };

    /*
     * The pin is re-checked on every launch and not only on download, which
     * is netinstall's rule for the launcher and had no counterpart here.
     * This used to return the first directory holding two files with the
     * right names, so an app directory somebody had been in was reused
     * without anything being looked at -- and what is in there is what
     * Assembly.LoadFrom loads.
     *
     * A package that does not match is not an error on its own. It is what
     * an older pin looks like after this file is updated, so the answer is
     * to fetch the one this build names; downloadWebView2WithProgress
     * deletes the directory before writing to it. It only becomes fatal
     * when a freshly extracted package is still wrong, because then it is
     * not staleness.
     */
    NeutrinoWebview.ensureWebView2Package = function (SystemRef, appFolder) {
        var existingLibDir = this.findWebView2LibDir(SystemRef, appFolder);
        if (existingLibDir &&
            !this.firstBadWebView2Member(SystemRef, this.webView2PackageRootOf(SystemRef, existingLibDir))) {
            return existingLibDir;
        }

        if (!SystemRef.IO.Directory.Exists(appFolder)) {
            SystemRef.IO.Directory.CreateDirectory(appFolder);
        }

        this.downloadWebView2WithProgress(SystemRef, appFolder);

        var libDir = this.findWebView2LibDir(SystemRef, appFolder);

        if (!libDir) {
            throw new Error("WebView2 package download completed but required assemblies were not found.");
        }

        var bad = this.firstBadWebView2Member(SystemRef, this.webView2PackageRootOf(SystemRef, libDir));
        if (bad) {
            throw new Error("WebView2 package member does not match its pin: " + bad);
        }
        return libDir;
    };

