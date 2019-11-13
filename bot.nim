import asyncdispatch, httpclient, json, os, parsecfg, strformat, strutils

import irc

var
  config: Config
  connected: bool

proc getPass(section, name: string): string =
  let
    f = config.getSectionValue(section, name).expandTilde()
  return f.readFile().strip()

proc postSlack(channel, text, user="", avatar="", retry=2): Future[bool] {.async.} =
  if text.len == 0 or retry == 0:
    return

  var
    client = newAsyncHttpClient()
    params = newJObject()
    resp: string
    url = "https://slack.com/api/chat.postMessage"

  params["channel"] = %* ("#" & channel)
  params["text"] = %* text
  if user.len != 0:
    params["as_user"] = %* "false"
    params["username"] = %* user
    if avatar.len != 0:
      params["icon_url"] = %* avatar
  else:
    params["as_user"] = %* "true"
  params["unfurl_media"] = %* "false"
  params["unfurl_links"] = %* "false"

  client.headers = newHttpHeaders({
    "Content-type": "application/json",
    "Authorization": "Bearer " & getPass("slack", "token")
  })

  echo "Posting to slack"
  try:
    resp = await client.postContent(url, $params)
  except:
    sleep(30000)
    echo "Retry connection error"
    return await postSlack(channel, text, user, avatar, retry-1)

  if resp.len != 0:
    if parseJson(resp)["ok"].getBool == false:
      echo resp
      sleep(30000)
      echo "Retry since returned false"
      return await postSlack(channel, text, user, avatar, retry-1)
  else:
    sleep(30000)
    echo "Retry since blank reply from Slack"
    return await postSlack(channel, text, user, avatar, retry-1)

  return true

proc ircBot() =
  let
    pno = Port(parseInt(config.getSectionValue("irc", "port")))

  var
    irc: AsyncIrc

  proc eventHandler(irc: AsyncIrc; event: IrcEvent) {.async.} =
    var
      chan, text: string
    case event.typ:
      of EvDisconnected:
        if connected:
          echo "disconnected; reconnecting..."
          discard irc.reconnect()
        else:
          echo "failed to connect to irc, check info"
          quit(1)
      of EvMsg:
        case event.cmd:
          of MPrivMsg:
            (chan, text) = (event.params[0], event.params[1])
            echo event.nick, "@", chan, ": ", text
            if chan == config.getSectionValue("irc", "nick"):
              # From IRC PM to Slack
              discard await postSlack(
                config.getSectionValue("slack", "channel"),
                text, user = event.nick
              )
            elif chan == "#" & config.getSectionValue("irc", "channel"):
              # From Slack to IRC PM
              if ":" in text:
                let
                  spl = text.split(":", maxsplit = 1)
                  nick = spl[0]
                  msg = if spl.len == 2: spl[1].strip() else: ""

                if nick.len != 0 and msg.len != 0:
                  await irc.privMsg(nick, msg)
          of MQuit:
            echo event.nick, " quit"
          of MPart:
            chan = event.params[0]
            echo event.nick, " left " & chan
          of MJoin:
            chan = event.params[0]
            echo event.nick, " joined " & chan
          of MNotice:
            (chan, text) = (event.params[0], event.params[1])
            echo event.nick, "@", chan, ": ", text
          of MPong:
            discard
          of MPing:
            discard
          else:
            text = event.params[0]
            if event.nick != "":
              echo event
      of EvConnected:
        echo "connected"
        connected = true
      else:
        echo event

  irc = newAsyncIrc(
    address = config.getSectionValue("irc", "host"),
    port = pno,
    nick = config.getSectionValue("irc", "nick"),
    realname = config.getSectionValue("irc", "name"),
    serverPass = getPass("irc", "pass"),
    callback=eventHandler,
    useSsl = config.getSectionValue("irc", "ssl") == "true"
  )
  waitfor irc.run()

when isMainModule:
  config = loadConfig("bot.ini")

  ircBot()

