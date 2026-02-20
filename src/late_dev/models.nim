import options

type
    json_string * = string

    platforms* = enum
        twitter
        threads
        facebook
        instagram
        linkedin
        pinterest
        youtube
        tiktok
        google_business_profile
        telegram
        bluesky
        snapchat
        reddit

    visibility_types* = enum
        public
        private
        unlisted

    parse_mode_types* = enum
        HTML
        Markdown
        MarkdownV2

    privacy_level_types* = enum
        PUBLIC_TO_EVERYONE
        MUTUAL_FOLLOW_FRIENDS
        FOLLOWER_OF_CREATOR
        SELF_ONLY

    commercial_content_types* = enum
        none
        brand_organic
        brand_content

    cta_types* = enum
        LEARN_MORE
        BOOK
        ORDER
        SHOP
        SIGN_UP
        CALL

    graduation_strategy_types* = enum
        MANUAL
        SS_PERFORMANCE

    media_type_types* = enum
        video
        photo

    # Sub-types
    userTag      * = object
        username * : string
        x        * : 0.0..1.0    # 0.0–1.0
        y        * : 0.0..1.0    # 0.0–1.0

    mediaItemTypes * = enum
        image
        video
        gif
        document
    
    mediaItem     * = object
        `type`    * : mediaItemTypes
        url       * : string
        filename  * : string

    threadItem     * = object
        content    * : string
        mediaItems * : Option[seq[mediaItem]]

    trialParams            * = object
        graduationStrategy *: Option[graduation_strategy_types]

    callToAction * = object
        `type`   * : cta_types
        url      * : string

    tiktokSettings                * = object
        privacy_level             * : privacy_level_types = PUBLIC_TO_EVERYONE
        allow_comment             * = true
        allow_duet                * = some false
        allow_stitch              * = some false
        content_preview_confirmed * = true # ⚠️ Required Consent: TikTok posts will fail without content_preview_confirmed: true and express_consent_given: true
        express_consent_given     * = true # ⚠️ Required Consent: TikTok posts will fail without content_preview_confirmed: true and express_consent_given: true
        draft                     * = some false
        description               * : Option[string]    # max 4000 chars for photo posts
        video_cover_timestamp_ms  * : Option[int]    # default: 1000
        photo_cover_index         * : Option[int]    # 0-based, default: 0
        auto_add_music            * : Option[bool]    # photos only
        video_made_with_ai        * = some false
        commercial_content_type   * : Option[commercial_content_types] = some none
        brand_partner_promote     * : Option[bool]    
        is_brand_organic_post     * : Option[bool]
        #media_type                * : Option[string] # Optional override (defaults based on media items)


    content_types* = enum
        reel
        story
        feed

    snapchat_content_types* = enum
        story
        saved_story
        spotlight


    # https://docs.getlate.dev/core/platform-settings
    platformSpecificData * = object
        firstComment          * : Option[string]
        contentType           * : Option[content_types]            # FB, IG
        snapchatContentType   * : Option[snapchat_content_types]   # Snapchat

        case kind             * : platforms
        of twitter, threads:
            threadItems       * : Option[seq[threadItem]]

        of facebook:
            pageId            * : Option[string]

        of instagram:
            userTags          * : Option[seq[userTag]]
            shareToFeed       * : Option[bool]                     # Reels only, default true
            collaborators     * : Option[seq[string]]              # up to 3 usernames
            trialParams       * : Option[trialParams]              # Reels only
            audioName         * : Option[string]                   # Reels only (set once)

        of linkedin:
            disableLinkPreview * : Option[bool]                    # default: false

        of pinterest:
            title             * : Option[string]                   # max 100 chars
            boardId           * : Option[string]
            link              * : Option[string]                   # URI
            coverImageUrl     * : Option[string]                   # URI for video pins
            coverImageKeyFrameTime
                              * : Option[int]                      # seconds

        of youtube:
            ytTitle           * : Option[string]                   # max 100 chars
            visibility        * : Option[visibility_types]         # default: public
            tags              * : Option[seq[string]]              # each <=100 chars, total <=500 chars
            containsSyntheticMedia
                              * : Option[bool]                     # disclosure flag

        of tiktok:
            tiktokSettings    * : Option[tiktokSettings]

        of google_business_profile:
            callToAction      * : Option[callToAction]

        of telegram:
            parseMode         * : Option[parse_mode_types]         # default: HTML
            disableWebPagePreview
                              * : Option[bool]
            disableNotification
                              * : Option[bool]
            protectContent    * : Option[bool]

        of bluesky:
            discard                                                # no platformSpecificData required

        of snapchat:
            discard                                                # uses snapchatContentType (top-level field)

        of reddit:
            discard                                                # no platformSpecificData required (for now)

    platform                 * = object
        platform             * : string
        accountId            * : string
        platformSpecificData * : Option[platformSpecificData]



# -----------------------------
# Platform settings helpers
# -----------------------------
discard """
https://docs.getlate.dev/core/platform-settings
"""
proc pTwitterThread*(
    accountId             : string
    ,threadItems          : seq[threadItem]
    ,firstComment         = none string
) : platform =
    platform(
        platform            : "twitter"
        ,accountId          : accountId
        ,platformSpecificData : some platformSpecificData(
            kind            : twitter
            ,threadItems    : some threadItems
            ,firstComment   : firstComment
        )
    )


discard """
https://docs.getlate.dev/core/platform-settings
"""
proc pThreadsThread*(
    accountId             : string
    ,threadItems          : seq[threadItem]
    ,firstComment         = none string
) : platform =
    platform(
        platform            : "threads"
        ,accountId          : accountId
        ,platformSpecificData : some platformSpecificData(
            kind            : threads
            ,threadItems    : some threadItems
            ,firstComment   : firstComment
        )
    )


discard """
https://docs.getlate.dev/core/platform-settings
"""
proc pFacebookFeed*(
    accountId             : string
    ,firstComment         = none string
    ,pageId               = none string
) : platform =
    platform(
        platform            : "facebook"
        ,accountId          : accountId
        ,platformSpecificData : some platformSpecificData(
            kind            : facebook
            ,firstComment   : firstComment
            ,pageId         : pageId
        )
    )


discard """
https://docs.getlate.dev/core/platform-settings
"""
proc pFacebookStory*(
    accountId             : string
    ,pageId               = none string
) : platform =
    platform(
        platform            : "facebook"
        ,accountId          : accountId
        ,platformSpecificData : some platformSpecificData(
            kind            : facebook
            ,contentType    : some content_types.story
            ,pageId         : pageId
        )
    )


discard """
https://docs.getlate.dev/core/platform-settings
"""
proc pLinkedIn*(
    accountId             : string
    ,firstComment         = none string
    ,disableLinkPreview   = none bool
) : platform =
    platform(
        platform            : "linkedin"
        ,accountId          : accountId
        ,platformSpecificData : some platformSpecificData(
            kind              : linkedin
            ,firstComment     : firstComment
            ,disableLinkPreview : disableLinkPreview
        )
    )


discard """
https://docs.getlate.dev/core/platform-settings
"""
proc pPinterest*(
    accountId             : string
    ,title                = none string
    ,boardId              = none string
    ,link                 = none string
    ,coverImageUrl        = none string
    ,coverImageKeyFrameTime = none int
) : platform =
    platform(
        platform            : "pinterest"
        ,accountId          : accountId
        ,platformSpecificData : some platformSpecificData(
            kind               : pinterest
            ,title             : title
            ,boardId           : boardId
            ,link              : link
            ,coverImageUrl     : coverImageUrl
            ,coverImageKeyFrameTime : coverImageKeyFrameTime
        )
    )


discard """
https://docs.getlate.dev/core/platform-settings
"""
proc pYouTube*(
    accountId             : string
    ,ytTitle              = none string
    ,visibility           = none visibility_types
    ,firstComment         = none string
    ,tags                 = none seq[string]
) : platform =
    platform(
        platform            : "youtube"
        ,accountId          : accountId
        ,platformSpecificData : some platformSpecificData(
            kind             : youtube
            ,ytTitle         : ytTitle
            ,visibility      : visibility
            ,firstComment    : firstComment
            ,tags            : tags
        )
    )


discard """
https://docs.getlate.dev/core/platform-settings
"""
proc pGoogleBusinessProfile*(
    accountId             : string
    ,cta_type             : cta_types
    ,cta_url              : string
) : platform =
    platform(
        platform            : "google_business_profile"
        ,accountId          : accountId
        ,platformSpecificData : some platformSpecificData(
            kind             : google_business_profile
            ,callToAction    : some callToAction(
                `type`       : cta_type
                ,url         : cta_url
            )
        )
    )


discard """
https://docs.getlate.dev/core/platform-settings
"""
proc pTelegram*(
    accountId             : string
    ,parseMode            = none parse_mode_types
    ,disableWebPagePreview= none bool
    ,disableNotification  = none bool
    ,protectContent       = none bool
) : platform =
    platform(
        platform            : "telegram"
        ,accountId          : accountId
        ,platformSpecificData : some platformSpecificData(
            kind                : telegram
            ,parseMode           : parseMode
            ,disableWebPagePreview : disableWebPagePreview
            ,disableNotification : disableNotification
            ,protectContent      : protectContent
        )
    )


proc pIGReel*(
    accountId      : string
    ,firstComment  = none string
    ,userTags      = none seq[userTag]
    ,shareToFeed   = none bool  # Reels only, default true
    ,collaborators = none seq[string]
    ,trialParams   = none trialParams # Reels only
    
) : platform = platform(
        platform               : "instagram"
        ,accountId             : accountId
        ,platformSpecificData  : some platformSpecificData(
            kind               : instagram
            ,contentType       : some content_types.reel
            ,firstComment      : firstComment
            ,userTags          : userTags
            ,shareToFeed       : shareToFeed
            ,collaborators     : collaborators
            ,trialParams       : trialParams
    ))

proc pIGStory*(
    accountId      : string
    ,firstComment  = none string
    ,userTags      = none seq[userTag]
    
) : platform = platform(
        platform               : "instagram"
        ,accountId             : accountId
        ,platformSpecificData  : some platformSpecificData(
            kind               : instagram
            ,contentType       : some content_types.story
            ,firstComment      : firstComment
            ,userTags          : userTags
    ))


proc pTiktok*(
    accountId     : string
    ,firstComment = none string
    ,settings     = some tiktokSettings()
    
) : platform = platform(
        platform               : "tiktok"
        ,accountId             : accountId
        ,platformSpecificData  : some platformSpecificData(
            kind               : tiktok
            ,firstComment      : firstComment
            ,tiktokSettings    : settings
))



proc miVideo*(url: string, filename: string): mediaItem = mediaItem(
        `type`     : video
        ,url       : url
        ,filename  : filename
    )
proc miImage*(url: string, filename: string): mediaItem = mediaItem(
        `type`     : image
        ,url       : url
        ,filename  : filename
    )
proc miGif*(url: string, filename: string): mediaItem = mediaItem(
        `type`     : gif
        ,url       : url
        ,filename  : filename
    )
proc miDoc*(url: string, filename: string): mediaItem = mediaItem(
        `type`     : document
        ,url       : url
        ,filename  : filename
    )