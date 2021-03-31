class TramAI extends AIInfo {
    function GetAuthor()      { return "mmuszkow"; }
    function GetName()        { return "TramAI"; }
    function GetDescription() { return "AI using only trams"; }
    function GetVersion()     { return 2; }
    function GetDate()        { return "2021-04-01"; }
    function CreateInstance() { return "TramAI"; }
    function GetShortName()   { return "TRAM"; }
    function GetAPIVersion () { return "1.10"; } /* for AIEngine.CanRunOnRoad */
    function UseAsRandomAI()  { return false; }
}

RegisterAI(TramAI());
