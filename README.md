# twitter-lib
Shell library to do Twitter API calls

### What's this?

This is a barebones implementation of Twitter API [OAuth signing](https://developer.twitter.com/en/docs/basics/authentication/guides/creating-a-signature.html) and [request sending](https://developer.twitter.com/en/docs/basics/authentication/guides/authorizing-a-request). It's a shell library that uses only **`bash`** and basic utilities. It can be used as a starting point to implement more complex Twitter application logics.

## Dependencies

The only dependencies needed are [**`bash`**](https://www.gnu.org/software/bash/), [**`curl`**](https://curl.haxx.se/), **`awk`** (any version should work), [**`openssl`**](https://www.openssl.org/) for the crypto part, **`sort`** and GNU **`date`**.

## Installation

No special installation needed. Just put **`twitter-lib.sh`** wherever you want. You have to know the location because you'll have to source it in your script.

## Getting started

- You need a [Twitter developer account](https://developer.twitter.com/) to use the API.

- Create an application in your [Twitter apps control panel](https://apps.twitter.com). Name it whatever you want, and use a made-up return URL (eg, http://localhost/). It's not used here, but it has to be present.

- Go to "Keys and Access Tokens" and get the following values: "Consumer Key (API Key)", "Consumer Secret (API Secret)" from the "Application Settings" section, and "Access Token" and "Access Token Secret" from the "Your Access Token" section.

- Source **`twitter-lib.sh`** in your script

- Implement a function called **`tt_get_userdef_credentials`** that sets the following environment variables with the corresponding values from your application: **`tt_oauth_consumer_key`**, **`tt_oauth_consumer_secret`**, **` tt_oauth_token`**, **`tt_oauth_token_secret`**. You can also optionally set **`tt_user_agent`** with the name of your app if you want, this will be set in API requests.

- Call **`tt_do_call`** with the appropriate values to start using the API. See below for examples.

## Logging

Sourcing the library gives you access to a very rudimental log function called `tt_log`. Its arguments are a log level (one of  DEBUG, INFO, NOTICE, WARNING, ERROR) and the message to log. You can use this function to log your application messages together with those coming from the library. By default, the library detects automatically whether to log to file or to stdout (if stdout is not a terminal, log to file; otherwise log to stdout). This allows eg running from cron without getting output, but still being able to manually run on the command line and see the messages. The log destination can however be forced. The minimum logging level can also be configured, or logging can be turned off altogether. See code below for examples.

## Internals

Internal communication is via global variables.

After each file API function invocation, the three variables **`tt_last_http_headers`**, **`tt_last_http_body`** and **`tt_last_http_code`** contain what their name says, so they can be inspected in your code for extra control.

**`tt_do_call`** computes OAuth credentials for the request and ends up calling **`tt_do_curl`** with appropriate arguments.

## Sample code

Note: you might not be able to perform certain API calls, depending on the permission you assigned to your application.

Arguments to **`tt_do_call`** are: HTTP method, URL, arguments, in this order. See [the API reference](https://developer.twitter.com/en/docs/api-reference-index) for available API calls.

```
#!/bin/bash

# you must implement this function with the right values
tt_get_userdef_credentials(){
  tt_oauth_consumer_key="xxxxxxxxxx"
  tt_oauth_consumer_secret="yyyyyyyyyyyyyyy"
  tt_oauth_token="zzzzzzzzzzzzzzzzzzzz"
  tt_oauth_token_secret="wwwwwwwwwwwwwwwwwwwww"
  tt_user_agent="My Super Twitter App/1.0"    # optional
}

. /path/to/twitter-lib.sh

# OPTIONAL: configure logging

# tt_set_log_level DEBUG        # valid values: DEBUG, INFO, NOTICE, WARNING], ERROR
# tt_set_logging_enabled 1      # valid values: 0 = logging disabled, anything else = enabled
# tt_set_log_destination file   # valid values: file = log to file, stdout = log to stdout (doh!)
                                # default file: /tmp/tt_YYYY-MM-DD_hh:mm:ss.log

############### Get user information
user_id="123456789"
tt_do_call GET "https://api.twitter.com/1.1/users/show.json" "user_id=${user_id}" "include_entities=false"

if [ $? -ne 0 ]; then
  # Error preventing the call from being made
  tt_log ERROR Terminating
  exit 1
fi

if [ "$tt_last_http_code" != "200" ]; then
  tt_log ERROR "Error getting user details" 
  # inspect $tt_last_http_headers, $tt_last_http_body etc
else
  user_name=$(jq -r '.name' <<< "$tt_last_http_body")
  user_screen_name=$(jq -r '.screen_name' <<< "$tt_last_http_body")
  user_description=$(jq -r '.description' <<< "$tt_last_http_body")
  user_followers=$(jq -r '.followers_count' <<< "$tt_last_http_body")
  # etc.
fi

############### Publish a tweet

tweet_text="This is a tweet submitted via the API."
tt_do_call POST "https://api.twitter.com/1.1/statuses/update.json" "status=${tweet_text}"

if [ $? -ne 0 ]; then
  # Error preventing the call from being made
  tt_log ERROR Terminating
  exit 1
fi

if [ "$tt_last_http_code" != "200" ]; then
  tt_log ERROR "Error submitting tweet"
  # inspect $tt_last_http_headers, $tt_last_http_body etc
else
  tweet_id=$(jq -r '.id_str' <<< "$tt_last_http_body")
  # etc.  
fi

############### Get user timeline

# Error checking omitted for brevity

user_id="123456789"
tweet_count=100
tt_do_call GET "https://api.twitter.com/1.1/statuses/user_timeline.json" "user_id=${user_id}" "count=${tweet_count}"

# print all tweets
while IFS= read -r tweet; do
  jq -r '.text' <<< "$tweet"
  echo "----------"
done < <(jq -c '.[]' <<< "$tt_last_http_body")

# ...more API calls here...

```
