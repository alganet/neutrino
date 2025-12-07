// SPDX-FileCopyrightText: 2025 Alexandre Gomes Gaigalas <alganet@gmail.com>
//
// SPDX-License-Identifier: ISC

import System;
import System.IO;
import System.Windows.Forms;

class NeutrinoWindowsHost {
    static function Log(message) {
        try {
            var path = Path.Combine(Application.StartupPath, "windows-app.log");
            File.AppendAllText(path, "[" + DateTime.Now.ToString("u") + "] " + message + Environment.NewLine);
        } catch (_) {
        }
    }

    static function ShowError(message) {
        MessageBox.Show(String(message), "neutrino - Windows", MessageBoxButtons.OK, MessageBoxIcon.Error);
        Environment.Exit(1);
    }
}
