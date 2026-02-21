import
    std / [
        options
    ]


type
    GldConfig       * = object
        apiKey      * : string
        profileId   * : Option[string]


    Upload* = object
        filename    * : string
        contentType * : string
        size        * : Option[int]
        uploadUrl   * : string
        publicUrl   * : string


    UploadsFile* = object
        uploads     * : seq[Upload]
