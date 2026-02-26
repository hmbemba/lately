import
    std / [
        options
    ]

# Import download provider types
import
    ../../lately/download_providers

export download_providers.DownloadProviderKind
export download_providers.PlatformProviderOverride
export download_providers.ProviderConfig


type
    GldConfig       * = object
        apiKey      * : string
        profileId   * : Option[string]
        downloadDir * : Option[string]  ## Custom download directory (default: .gld/downloads)
        providerConfig* : ProviderConfig  ## Download provider configuration


    Upload* = object
        filename    * : string
        contentType * : string
        size        * : Option[int]
        uploadUrl   * : string
        publicUrl   * : string


    UploadsFile* = object
        uploads     * : seq[Upload]
