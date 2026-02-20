import
    std / [
        os
        ,strutils
        ,options
        ,algorithm
    ]

import
    jsony
    ,ic

import
    ./paths
    ,./types


proc defaultUploads*() : UploadsFile =
    result = UploadsFile(
        uploads : @[]
    )


proc loadUploads*() : UploadsFile =
    let p = uploadsPath()
    if not fileExists(p):
        return defaultUploads()

    let raw = readFile(p)
    if raw.strip.len == 0:
        return defaultUploads()

    try:
        return raw.fromJson(UploadsFile)
    except CatchableError as e:
        icr "Failed to parse uploads file. Using empty.", e.msg
        return defaultUploads()


proc saveUploads*(uf: UploadsFile) =
    let p = uploadsPath()
    p.writeFile(uf.toJson())


proc addOrUpdateUpload*(uf: var UploadsFile, u: Upload) =
    ## Replace by publicUrl if already present, else append.
    for i in 0 ..< uf.uploads.len:
        if uf.uploads[i].publicUrl == u.publicUrl:
            uf.uploads[i] = u
            return
    uf.uploads.add u


proc sortUploadsNewestish*(uf: var UploadsFile) =
    ## No timestamp in schema; sort by filename for stable output.
    uf.uploads.sort(proc(a, b: Upload): int = cmp(a.filename, b.filename))
