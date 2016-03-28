/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the license, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this software.  If not, see <http://www.gnu.org/licenses/>.
 */

module ag.extractor;

import std.stdio;
import std.string;
import appstream.Component;

import ag.config;
import ag.hint;
import ag.result;
import ag.backend.intf;
import ag.datacache;
import ag.handlers;


class DataExtractor
{

private:
    Component[] cpts;
    GeneratorHint[] hints;

    DataCache dcache;
    IconHandler iconh;
    Config conf;
    DataType dtype;

public:

    this (DataCache cache, IconHandler iconHandler)
    {
        dcache = cache;
        iconh = iconHandler;
        conf = Config.get ();
        dtype = conf.metadataType;
    }

    GeneratorResult processPackage (Package pkg)
    {
        // create a new result container
        auto gres = new GeneratorResult (pkg);

        // prepare a list of metadata files which interest us
        string[string] desktopFiles;
        string[] metadataFiles;
        foreach (string fname; pkg.contents) {
            if ((fname.startsWith ("/usr/share/applications")) && (fname.endsWith (".desktop"))) {
                desktopFiles[baseName (fname)] = fname;
                continue;
            }
            if ((fname.startsWith ("/usr/share/appdata")) && (fname.endsWith (".xml"))) {
                metadataFiles ~= fname;
                continue;
            }
            if ((fname.startsWith ("/usr/share/metainfo")) && (fname.endsWith (".xml"))) {
                metadataFiles ~= fname;
                continue;
            }
        }

        // now process metainfo XML files
        foreach (string mfname; metadataFiles) {
            if (!mfname.endsWith (".xml"))
                continue;

            auto data = pkg.getFileData (mfname);
            auto cpt = parseMetaInfoFile (gres, data);
            if (cpt is null)
                continue;

            // check if we need to extend this component's data with data from its .desktop file
            auto cid = cpt.getId ();
            if (cid.empty) {
                gres.addHint ("general", "metainfo-no-id", ["fname": mfname]);
                continue;
            }

            auto dfp = (cid in desktopFiles);
            if (dfp is null) {
                // no .desktop file was found
                // finalize GCID checksum and continue
                gres.updateComponentGCID (cpt, data);

                if (cpt.getKind () == ComponentKind.DESKTOP) {
                    // we have a DESKTOP_APP component, but no .desktop file. This is a bug.
                    gres.addHint (cpt.getId (), "missing-desktop-file");
                    continue;
                }

                // do a validation of the file. Validation is slow, so we allow
                // the user to disable this feature.
                if (conf.featureEnabled (GeneratorFeature.VALIDATE)) {
                    if (!dcache.metadataExists (dtype, gres.gcidForComponent (cpt)))
                        validateMetaInfoFile (cpt, gres, data);
                }
                continue;
            }

            // update component with .desktop file data, ignoring NoDisplay field
            auto ddata = pkg.getFileData (*dfp);
            parseDesktopFile (gres, *dfp, ddata, true);

            // update GCID checksum
            gres.updateComponentGCID (cpt, data ~ ddata);

            // drop the .desktop file from the list, it has been handled
            desktopFiles.remove (cid);

            // do a validation of the file. Validation is slow, so we allow
            // the user to disable this feature.
            if (conf.featureEnabled (GeneratorFeature.VALIDATE)) {
                if (!dcache.metadataExists (dtype, gres.gcidForComponent (cpt)))
                    validateMetaInfoFile (cpt, gres, data);
            }
        }

        // process the remaining .desktop files
        foreach (string dfname; desktopFiles.byValue ()) {
            auto data = pkg.getFileData (dfname);
            auto cpt = parseDesktopFile (gres, dfname, data, false);
            if (cpt !is null)
                gres.updateComponentGCID (cpt, data);
        }


        foreach (cpt; gres.getComponents ()) {
            auto gcid = gres.gcidForComponent (cpt);

            // don't run expensive operations if the metadata already exists
            if (dcache.metadataExists (dtype, gcid))
                continue;

            // find & store icons
            iconh.process (gres, cpt);

            // download and resize screenshots
            if (conf.featureEnabled (GeneratorFeature.SCREENSHOTS))
                processScreenshots (gres, cpt, dcache.mediaExportDir);

            // inject package descriptions, if needed
            auto ckind = cpt.getKind ();
            if (ckind == ComponentKind.DESKTOP) {
                cpt.setActiveLocale ("C");
                if (cpt.getDescription ().empty) {
                    auto descP = "C" in pkg.description;
                    if (descP !is null) {
                        cpt.setDescription (*descP, "C");
                        gres.addHint (cpt.getId (), "description-from-package");
                    }
                }
            }
        }

        // this removes invalid components and cleans up the result
        gres.finalize ();
        pkg.close ();

        return gres;
    }
}
