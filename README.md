# has - Higher Availability Service
This service is to allow user connections to survive restarts of your MUSH, restarts of the server hosting the MUSH, and fail overs to another machine. 
# High level, How does it work?
The user connects to the HAS service as if it was the MUSH and the HAS service opens a connection to the MUSH. THe HAS service then handles the task of relying information between the user and the MUSH. If the MUSH is unavailible for any reason, the HAS service tells the user the MUSH is down. Once the MUSH is availible, the user is informed the MUSH is online, reconnects, and logs the user in. Everything then returns to normal at this point. Also see fail over below.
# Lower level, How does this work?
- Disconnects:
  There are two basic reasons why this may happen. 1) If the user QUITs or is @booted. 2) the MUSH server goes down. Telling the difference between these two events is a tricky because the HAS service only knows the connection to the MUSH was dropped. It has no idea *WHY*. To figure out why, The HAS serverice issues a simple think command to the MUSH via the HeartBeat user. If MUSH responds, the user QUIT or was @booted. If no responce is given, then the MUSH server is down.
- Connections:
   When a user connects to the HAS server, the HAS server connects to the MUSH and issues a @remotehost command on the users connection. This command tells the MUSH the user's actual hostname. Without this hint, the MUSH will only see users connecting from the HAS server's machine and not its true location. The MUSH server should only accept this command once, from the HAS server's machine, and only before the user authenticates.
- Login Details:
   The script currently looks for the user to type a 'connect <user> <password>' command. Once detected, the HAS service queries the MUSH via a password(user,password) function to determine if the user typed in a valid user and password. If it did, it stores the user / password pair in memory for use when reconnecting. This function will need to be changed to support other MUSH server types.
- Fail Over:
    This will be supported in the next version of the HAS server. The idea will be that if the MUSH server goes down, the code will fail over to a different server after a set amount of time. Currently, the server only supports manual fail over in which the mush address is changed within the script and then the running process is sent a HUP signal.
