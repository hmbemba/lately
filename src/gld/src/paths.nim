import
    std / [
        os
    ]

import
    mynimlib/utils


proc appDir*() : string =
    ## Directory containing gld.exe
    result = getAppDir()


proc gldDir*() : string =
    ## .gld directory created next to gld.exe
    result = dirExistsOrMk(appDir() / ".gld")


proc configPath*() : string =
    result = gldDir() / "gld.config.json"


proc uploadsPath*() : string =
    result = gldDir() / "gld.uploads.json"
