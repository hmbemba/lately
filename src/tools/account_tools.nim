## account_tools.nim - Account management tools for GLD Agent
##
## Tools for listing accounts, checking health, and managing connections.

import
    std/[
        json
        ,asyncdispatch
        ,strformat
        ,options
    ]

import
    llmm
    ,llmm/tools

import
    ../lately/accounts as late_accounts
    ,../gld/src/store_config
    ,agent_config

# -----------------------------------------------------------------------------
# List Accounts Tool
# -----------------------------------------------------------------------------

proc ListAccountsTool*(): Tool =
    ## List all connected social media accounts
    Tool(
        name        : "list_accounts"
        ,description: "List all connected social media accounts with their platform, username, and status."
        ,parameters : %*{
            "type": "object"
            ,"properties": {}
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                let conf = loadConfig()
                let apiKey = requireApiKey(conf)

                let res = await late_accounts.listAccounts(apiKey)

                if not res.ok:
                    return toolError(&"Failed to list accounts: {res.err}")

                let accounts = res.val.accounts
                var accountList: seq[JsonNode]

                for acct in accounts:
                    accountList.add %*{
                        "id": acct.id
                        ,"platform": $acct.platform
                        ,"username": acct.username.get("")
                        ,"displayName": acct.displayName.get("")
                        ,"isActive": acct.isActive.get(false)
                    }

                return toolSuccess(%*{
                    "accounts": accountList
                    ,"count": accounts.len
                    ,"hasAnalyticsAccess": res.val.hasAnalyticsAccess
                }, &"Found {accounts.len} connected account(s)")

            except CatchableError as e:
                return toolError(&"Error listing accounts: {e.msg}")
    )

# -----------------------------------------------------------------------------
# Account Health Tool
# -----------------------------------------------------------------------------

proc AccountHealthTool*(): Tool =
    ## Check health status of connected accounts
    Tool(
        name        : "check_account_health"
        ,description: "Check the health status of all connected accounts or a specific account. Shows token validity, permissions, and any issues."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "accountId": {
                    "type": "string"
                    ,"description": "Optional specific account ID to check. If not provided, checks all accounts."
                }
            }
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                let conf = loadConfig()
                let apiKey = requireApiKey(conf)

                let accountIdOpt = if args.hasKey("accountId") and args["accountId"].getStr.len > 0:
                    some(args["accountId"].getStr)
                else:
                    none(string)

                if accountIdOpt.isSome:
                    # Check specific account
                    let res = await late_accounts.accountHealth(apiKey, accountIdOpt.get)

                    if not res.ok:
                        return toolError(&"Failed to check account health: {res.err}")

                    let health = res.val
                    return toolSuccess(%*{
                        "accountId": health.accountId
                        ,"platform": health.platform
                        ,"username": health.username
                        ,"status": health.status
                        ,"issues": health.issues.get(@[])
                        ,"recommendations": health.recommendations.get(@[])
                    }, &"Account health: {health.status}")
                else:
                    # Check all accounts
                    let res = await late_accounts.accountsHealth(apiKey)

                    if not res.ok:
                        return toolError(&"Failed to check accounts health: {res.err}")

                    let health = res.val
                    var accountHealthList: seq[JsonNode]

                    for acct in health.accounts:
                        accountHealthList.add %*{
                            "accountId": acct.accountId
                            ,"platform": acct.platform
                            ,"username": acct.username
                            ,"status": acct.status
                            ,"canPost": acct.canPost
                            ,"needsReconnect": acct.needsReconnect
                            ,"issues": acct.issues.get(@[])
                        }

                    return toolSuccess(%*{
                        "summary": {
                            "total": health.summary.total
                            ,"healthy": health.summary.healthy
                            ,"warning": health.summary.warning
                            ,"error": health.summary.error
                            ,"needsReconnect": health.summary.needsReconnect
                        }
                        ,"accounts": accountHealthList
                    }, &"Health check complete: {health.summary.healthy}/{health.summary.total} healthy")

            except CatchableError as e:
                return toolError(&"Error checking account health: {e.msg}")
    )

# -----------------------------------------------------------------------------
# Account Toolkit
# -----------------------------------------------------------------------------

proc AccountToolkit*(): Toolkit =
    ## Toolkit for account management operations
    result = newToolkit("lately_accounts", "Manage connected social media accounts")
    result.add ListAccountsTool()
    result.add AccountHealthTool()
