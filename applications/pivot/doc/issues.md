/*                                                                                                                                                                                                                                                                                                 
Section: Pivot
Title: Issues
Language: en-US
*/

* Default data submitted on request: CallerName, Direction, ApiVerson, CallStatus, To, From, AccountSid, CallSid
* Play
  * Play audio from URL supplied as content of Play tag <Play>http://some.host.com/file/to/play.mp3</Play>
  * Support 'loop' attribute, to loop playing of the audio
  * Accept mp3 and wav audio files
  * Nestable in the <Gather> Verb
  * Cache retrieved audio
* Say
  * Convert text in content of Say tag into spoken words <Say>Hello world</Say>
  * Support 'voice' attribute with 'male' or 'female' as values; default 'male'
  * Support 'language' attribute with 'en', 'es'; default 'en'
  * Support 'loop' attribute, to loop saying the text
  * Nestable in the <Gather> Verb
  * If using 3rd party engine, cache generated audio file
  * Support using iSpeech as TTS engine
* Dial
  * Support dialing out to DID as content of Dial <Dial>4158867900</Dial>
  * Support dialing out to DID(s) as Number tag(s) <Dial><Number>+14158867900</Number>...</Dial>
  * Support dialing Kazoo Users directly <Dial><User>abc123</User>...</Dial>
  * Support dialing Kazoo Devices directly <Dial><Device>sdf234</Device>...</Dial>
  * Optionally support internal extension dialing
  * Support 'action' attribute to send followup request based on how the Dial went
  * Support setting the caller ID via 'callerId' attribute to a valid phone number (default is caller's ID)
* Pause
  * Support waiting silently for a specified number of seconds
  * Nestable in the <Gather> verb
* Gather
  * Collect DTMFs from caller, and send collection to url (current or specified by 'action' URL)
  * Support a timeout, which when breached, returns 'timeout' for the Digits field
  * Support custom finishOnKey DTMF tone (not collected) to end collection
  * Support collecting certain number of digits (default is unlimited)
  * Support nesting <Play>, <Say>, and <Pause>
