class TramAI extends AIInfo {
	function GetAuthor()      { return "mmuszkow"; }
	function GetName()        { return "TramAI"; }
	function GetDescription() { return "AI using only trams"; }
	function GetVersion()     { return 1; }
	function GetDate()        { return "2020-05-04"; }
	function CreateInstance() { return "TramAI"; }
	function GetShortName()   { return "TRAM"; }
    function GetURL()         { return ""; }
    function GetAPIVersion () { return "1.2"; } /* for AICompany.GetQuarterlyExpenses */
    function UseAsRandomAI()  { return false; }
}

RegisterAI(TramAI());
