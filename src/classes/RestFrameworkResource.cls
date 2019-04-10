/**
* @author Tiaan Swart (tiaan@cloudinit.nz)
* @date 2018-05-31
* @description Base RESTful Resource
*
* CHANGE LOG
**/
@RestResource( UrlMapping = '/api/*' )
global with sharing class RestFrameworkResource
{

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Request and Response Properties
    **/
    public static RestRequest req = RestContext.request;
    public static RestResponse res = RestContext.response;

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description HTTP Request Method
    *   @return String GET, HEAD, PUT, POST, PATCH, DELETE, OPTIONS
    **/
    public static String httpMethod {
        get {
            return req.httpMethod;
        }
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Custom Status Code Handling
    *   @return Integer HTTP Status Code 1XX, 2XX, 3XX, 4XX, 5XX
    **/
    public static Integer statusCode {
        get {
            if (statusCode == null) {
                statusCode = 200;
            }
            return statusCode;
        }
        private set;
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get the Request Remote Address (IP) as an Integer
    *   @return IP as an Integer
    **/
    public static Decimal remoteAddress {
        get {
            if (remoteAddress == null) {
                remoteAddress = Decimal.valueOf(req.remoteAddress.replaceAll('\\.', '0'));
            }
            return remoteAddress;
        }
        private set;
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get the Request URI in a List of Strings
    *   @return List of String Request URI Parts (example: ('v1','account', '{id}')
    **/
    @TestVisible
    private static List<String> requestURI {
        get {
            if (requestURI == null) {
                requestURI = req.requestURI.replace('/api/','').split('/');
            }
            return requestURI;
        }
        set;
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get the API Version from the first entry of requestURI
    *   @return String API Version
    **/
    @TestVisible
    private static String apiVersion {
        get {
            if (apiVersion == null) {
                apiVersion = requestURI.remove(0);
            }
            return apiVersion;
        }
        set;
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Handle Base API GET & HEAD
    **/
    @HttpGet
    global static void doGet()
    {
        processInboundRequest();
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Handle Base API POST
    **/
    @HttpPost
    global static void doPost()
    {
        processInboundRequest();
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Handle Base API PUT
    **/
    @HttpPut
    global static void doPut()
    {
        processInboundRequest();
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Handle Base API PUT
    **/
    @HttpPatch
    global static void doPatch()
    {
        processInboundRequest();
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Handle Base API Delete
    **/
    @HttpDelete
    global static void doDelete()
    {
        processInboundRequest();
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Process the Inbound Rest Request
    **/
    @TestVisible
    private static void processInboundRequest()
    {

        // Default Response
        Map<String, Object> responseMap = new Map<String, Object>{'records' => new List<Object>()};

        // Details required for logging purposes
        API_Version__c theApiVersion;
        API_Endpoint__c theApiEndpoint;
        String theAppliedApiPolicies;

        // ETag Property
        String ETag;

        // Create the API Log Entry
        API_Log_Entry__c theApiLogEntry = new API_Log_Entry__c();

        // Flag to set detail response or list response type
        Boolean isDetailGet = false;

        // Content Type of the request
        String contentType;

        try {

            // Get the API Version Record
            theApiVersion = RestFrameworkUtils.getApiVersion(apiVersion);

            // Get the Request ETag, if we have one
            String ETagRequest = req.headers.containsKey('If-None-Match') ? req.headers.get('If-None-Match') : req.headers.get('ETag');
            // Remove GZip if present
            if (String.isNotBlank(ETagRequest)) {
                ETagRequest = ETagRequest.replace('--gzip','');
            }

            /*
             * Get all the Detail Id's the user has requested, mapped by the API Endpoints
             */

            // Map of API Endpoint Record Ids to API Endpoints from the Request URI
            Map<String, String> RecordIdMapByApiEndpoint = new Map<String, String>();

            // While we have URI elements
            while (!requestURI.isEmpty()) {

                // Get the API Endpoint
                String theApi = requestURI.remove(0);

                // Get the Record Id (if any, should always follow API /v1/accounts/{Id}/contacts/{Id})
                String theRecordId = !requestURI.isEmpty() ? requestURI.remove(0) : null;

                // Map Record Id and API Endpoint
                RecordIdMapByApiEndpoint.put(theApi, theRecordId);

            }

            // Set of API Endpoints in the Request URI
            List<String> theRequestURIAPIEndpoints = new List<String>(RecordIdMapByApiEndpoint.keySet());

            /*
             * Get all the API Endpoints the user has access to that matches the API Endpoints for the request
             */

            // Now start at the lowest level of API requested
            String theApiEndpointName = theRequestURIAPIEndpoints.remove(theRequestURIAPIEndpoints.size()-1);
            String theDetailId = RecordIdMapByApiEndpoint.get(theApiEndpointName);

            // We need the theDetailId if we are going to perform a PUT, PATCH OR DELETE
            if ((new List<String>{'PUT','PATCH','DELETE'}).contains(httpMethod) && String.isBlank(theDetailId)) {

                throw new BadRequestException('HTTP method PUT, PATCH or DELETE requires a record Id');

            // POST should not contain a URI Id
            // @TODO it can however contain an Id in the Body to support Legacy Servers that only use POST
            } else if (httpMethod == 'POST' && String.isNotBlank(theDetailId)) {

                throw new BadRequestException('HTTP method POST must not have a record Id in the URI');

            }

            // Get the API Endpoint
            theApiEndpoint = RestFrameworkUtils.getApiEndpoint(theApiVersion, theApiEndpointName);

            /*
             * This part get's all the API Policies the user has access to that matches the API Version and / or Lowest Endpoint for the request
             * If we need to enforce any policies we will do so here
             */

            List<API_Policy__c> theApiPolicies;

            // Get the current time
            Datetime nowDatetime = Datetime.now();
            Time nowTime = Time.newInstance(nowDatetime.hour(), nowDatetime.minute(), nowDatetime.second(), nowDatetime.millisecond());

            // If we are only allowing whitelisting
            if (theApiVersion.Enforce_Whitelist_Policy__c) {

                theAppliedApiPolicies = '';

                // Select Policies that apply to the lowest level of API Endpoint requested
                theApiPolicies = [SELECT Type__c, API_Policy_Full_Name__c
                                  FROM API_Policy__c
                                  WHERE Type__c = 'Whitelist Policy' AND API_Version__c =: theApiVersion.Id AND Active__c = TRUE
                                        AND (API_Endpoint__c = NULL OR API_Endpoint__c =: theApiEndpoint.Id)
                                        AND (IP_Range_Start_Val__c <= :remoteAddress AND IP_Range_End_Val__c >= :remoteAddress)
                                        AND (Hours_Range_Start__c = NULL OR (Hours_Range_Start__c <= :nowTime AND Hours_Range_End__c >= :nowTime))
                                  LIMIT 50000];

                // If we have no policies to apply
                if (theApiPolicies.isEmpty()) {

                    throw new ForbiddenException('Access not allowed! IP not Whitelisted.');

                } else {

                    // For each policy
                    for (API_Policy__c theApiPolicy : theApiPolicies) {

                        // This Policy has been applied
                        theAppliedApiPolicies += String.format(
                            '{0}[{1}: {2}]',
                            new String[]{
                                String.isBlank(theAppliedApiPolicies) ? '' : ', ',
                                theApiPolicy.Type__c,
                                theApiPolicy.API_Policy_Full_Name__c
                            }
                        );

                    }

                }

                // Add policies to the Log Entry
                theApiLogEntry.API_Policies_Applied__c = theAppliedApiPolicies;

            }

            // If we are only allowing timed access
            if (theApiVersion.Enforce_Restrictive_Time_Policy__c) {

                theAppliedApiPolicies = String.isBlank(theAppliedApiPolicies) ? '' : theAppliedApiPolicies;

                // Select Policies that apply to the lowest level of API Endpoint requested
                theApiPolicies = [SELECT Type__c, API_Policy_Full_Name__c
                                  FROM API_Policy__c
                                  WHERE Type__c = 'Restrictive Time Policy' AND API_Version__c =: theApiVersion.Id AND Active__c = TRUE
                                        AND (API_Endpoint__c = NULL OR API_Endpoint__c =: theApiEndpoint.Id)
                                        AND (IP_Range_Start__c = NULL OR (IP_Range_Start_Val__c <= :remoteAddress AND IP_Range_End_Val__c >= :remoteAddress))
                                        AND (Hours_Range_Start__c <= :nowTime AND Hours_Range_End__c >= :nowTime)
                                  LIMIT 50000];

                // If we have no policies to apply
                if (theApiPolicies.isEmpty()) {

                    throw new ForbiddenException('Access not allowed! Outside of restricted time access.');

                } else {

                    // For each policy
                    for (API_Policy__c theApiPolicy : theApiPolicies) {

                        // This Policy has been applied
                        theAppliedApiPolicies += String.format(
                            '{0}[{1}: {2}]',
                            new String[]{
                                String.isBlank(theAppliedApiPolicies) ? '' : ', ',
                                theApiPolicy.Type__c,
                                theApiPolicy.API_Policy_Full_Name__c
                            }
                        );

                    }

                }

                // Add policies to the Log Entry
                theApiLogEntry.API_Policies_Applied__c = theAppliedApiPolicies;

            }

            // If we are only allowing limited access
            if (theApiVersion.Enforce_Access_Limit_Policy__c) {

                Decimal yearLimit;
                Decimal monthLimit;
                Decimal dayLimit;
                Decimal hourLimit;

                theAppliedApiPolicies = String.isBlank(theAppliedApiPolicies) ? '' : theAppliedApiPolicies;

                // Select Policies that apply to the lowest level of API Endpoint requested
                theApiPolicies = [SELECT Type__c, API_Policy_Full_Name__c, Access_Limit__c, Access_Limit_UOM__c
                                  FROM API_Policy__c
                                  WHERE Type__c = 'Access Limit Policy' AND API_Version__c =: theApiVersion.Id AND Active__c = TRUE
                                        AND Access_Limit_HTTP_Methods__c INCLUDES (:httpMethod)
                                        AND (API_Endpoint__c = NULL OR API_Endpoint__c =: theApiEndpoint.Id)
                                        AND (IP_Range_Start_Val__c <= :remoteAddress AND IP_Range_End_Val__c >= :remoteAddress)
                                        AND (Hours_Range_Start__c = NULL OR (Hours_Range_Start__c <= :nowTime AND Hours_Range_End__c >= :nowTime))
                                  LIMIT 50000];

                // If we have no policies to apply
                if (theApiPolicies.isEmpty()) {

                    throw new ForbiddenException('API access limit policy misconfiguration. No policies found!');

                } else {

                    // For each policy
                    for (API_Policy__c theApiPolicy : theApiPolicies) {

                        // Gather the lowest UOM
                        hourLimit = theApiPolicy.Access_Limit_UOM__c == 'Hour' && (hourLimit == null || hourLimit < theApiPolicy.Access_Limit__c) ? theApiPolicy.Access_Limit__c : hourLimit;
                        dayLimit = theApiPolicy.Access_Limit_UOM__c == 'Day' && (dayLimit == null || dayLimit < theApiPolicy.Access_Limit__c) ? theApiPolicy.Access_Limit__c : dayLimit;
                        monthLimit = theApiPolicy.Access_Limit_UOM__c == 'Month' && (monthLimit == null || monthLimit < theApiPolicy.Access_Limit__c) ? theApiPolicy.Access_Limit__c : monthLimit;
                        yearLimit = theApiPolicy.Access_Limit_UOM__c == 'Year' && (yearLimit == null || yearLimit < theApiPolicy.Access_Limit__c) ? theApiPolicy.Access_Limit__c : yearLimit;

                        // This Policy will be Applied
                        theAppliedApiPolicies += String.format(
                            '{0}[{1}: {2}]',
                            new String[]{
                                String.isBlank(theAppliedApiPolicies) ? '' : ', ',
                                theApiPolicy.Type__c,
                                theApiPolicy.API_Policy_Full_Name__c
                            }
                        );

                    }

                    // If we have a year limit, then check it
                    if (yearLimit != null) {
                        RestFrameworkUtils.checkAccessCount(theApiVersion.Id, (theApiEndpoint == null ? null : theApiEndpoint.Id), nowDatetime.addYears(-1), yearLimit, 'Year');
                    }

                    // If we have a month limit, then check it
                    if (monthLimit != null) {
                        RestFrameworkUtils.checkAccessCount(theApiVersion.Id, (theApiEndpoint == null ? null : theApiEndpoint.Id), nowDatetime.addMonths(-1), monthLimit, 'Month');
                    }

                    // If we have a day limit, then check it
                    if (dayLimit != null) {
                        RestFrameworkUtils.checkAccessCount(theApiVersion.Id, (theApiEndpoint == null ? null : theApiEndpoint.Id), nowDatetime.addDays(-1), dayLimit, 'Day');
                    }

                    // If we have a hour limit, then check it
                    if (hourLimit != null) {
                        RestFrameworkUtils.checkAccessCount(theApiVersion.Id, (theApiEndpoint == null ? null : theApiEndpoint.Id), nowDatetime.addHours(-1), hourLimit, 'Hour');
                    }

                }

                // Add policies to the Log Entry
                theApiLogEntry.API_Policies_Applied__c = theAppliedApiPolicies;

            }

            // Get the SObject Describe
            DescribeSObjectResult dsr = RestFrameworkUtils.getDsr(theApiEndpoint.SObject_API_Name__c);

            if (httpMethod == 'GET' || httpMethod == 'HEAD') {

                // Get the Content Type
                Set<String> allowedContentTypes = new Set<String>(theApiVersion.Allowed_Content_Types__c.split(';'));
                // If we have a content type
                if (req.headers.containsKey('Content-Type')) {
                    if (req.headers.get('Content-Type').toLowerCase() == 'text/xml' || req.headers.get('Content-Type').toLowerCase() == 'application/xml') {
                        contentType = 'XML';
                    } else if (req.headers.get('Content-Type').toLowerCase() == 'application/json') {
                        contentType = 'JSON';
                    } else {
                        contentType = req.headers.get('Content-Type');
                    }
                    // If we have an unsupported content type
                    if (!allowedContentTypes.contains(contentType)) {
                        throw new ForbiddenException('Unsupported Content-Type \''+contentType+'\'!');
                    }
                    // Else just set the first available one
                } else {
                    contentType = (new List<String>(allowedContentTypes))[0];
                }

                // Flag if this is a detail get
                isDetailGet = String.isNotBlank(theDetailId);

                // Get the fields for the SOQL Query
                List<String> fields = RestFrameworkUtils.getSObjectFieldsList(theApiEndpoint.SObject_API_Name__c);

                // Get the child relationships
                List<ChildRelationship> crs = dsr.getChildRelationships();

                // Map to keep the Child Relationship names so that we can use them later
                Map<String, API_Endpoint__c> childRelationshipMap = new Map<String, API_Endpoint__c>();

                // Add direct sub SOQL queries
                for (API_Endpoint__c theChildApiEndpoint : theApiEndpoint.API_Endpoints__r) {

                    API_Endpoint__c theEndpoint = RestFrameworkUtils.getApiEndpoint(theApiVersion, theChildApiEndpoint.Name);

                    // Get the relationship name
                    String relationshipName = '';
                    for (ChildRelationship cr : crs) {
                        if (cr.getChildSObject().getDescribe().getName() == theEndpoint.SObject_API_Name__c &&
                            cr.getField().getDescribe().getName() == theEndpoint.Parent_SObject_Id_Field__c) {
                            relationshipName = cr.getRelationshipName();
                            break;
                        }
                    }

                    // Map the Child Endpoint
                    childRelationshipMap.put(relationshipName, theEndpoint);

                    // Build the Sub SOQL Query and add to the fields
                    fields.add(
                        '(' +
                        RestFrameworkUtils.buildSOQL(
                            RestFrameworkUtils.getSObjectFieldsList(theEndpoint.SObject_API_Name__c),
                            relationshipName,
                            null,
                            null,
                            null
                        )
                        + ')'
                    );

                }

                // Init Custom Conditions
                List<String> customConditions = new List<String>();

                // Prev endpoint to keep track of where we have been / coming from
                API_Endpoint__c thePrevEndpoint = theApiEndpoint;

                // Running relationship field, used for Dot Notation mapping
                String runningRelField = '';

                // If we have Endpoints left then they must be Parent Endpoints and we need to add them to the Query
                while (!theRequestURIAPIEndpoints.isEmpty()) {

                    // Get the next lowest level Endpoint Name
                    String theEndpointName = theRequestURIAPIEndpoints.remove(theRequestURIAPIEndpoints.size() - 1);

                    // Get the Endpoint Id
                    String theEndpointDetailId = RecordIdMapByApiEndpoint.get(theEndpointName);

                    // Add the custom condition
                    customConditions.add(
                        String.format(
                            '{0}{1}{2} = ',
                            new String[] {
                                runningRelField,
                                String.isNotBlank(runningRelField) ? '.' : '',
                                thePrevEndpoint.Parent_SObject_Id_Field__c
                            }
                        ) + '\''+ theEndpointDetailId +'\''
                    );

                    // If we have more conditions to come we will need to get the mappings
                    if (!theRequestURIAPIEndpoints.isEmpty()) {

                        // Get the running relationship
                        runningRelField += (String.isNotBlank(runningRelField) ? '.' : '') +
                                           RestFrameworkUtils.getSObjectField(
                                               thePrevEndpoint.SObject_API_Name__c,
                                               thePrevEndpoint.Parent_SObject_Id_Field__c
                                           ).getDescribe().getRelationshipName();

                        // Set the Prev Endpoint
                        thePrevEndpoint = RestFrameworkUtils.getApiEndpoint(theApiVersion, theEndpointName);

                    }

                }

                // @TODO add Custom GET Params
                // @TODO add Pagination

                // Get results
                List<SObject> results = RestFrameworkUtils.getResults(
                    fields,
                    theApiEndpoint.SObject_API_Name__c,
                    theApiEndpoint.SObject_Id_Field__c,
                    theDetailId,
                    customConditions.isEmpty() ? '' : String.join(customConditions, ' AND ')
                );

                // Convert to Object
                List<Object> resultsMap = (List<Object>) JSON.deserializeUntyped(JSON.serialize(results));

                // @TODO add field mappings

                // If we have results
                if (!resultsMap.isEmpty()) {

                    // Build the record map
                    RestFrameworkUtils.buildRecordMap(resultsMap, theApiEndpoint, childRelationshipMap, false);

                    // Get the Final ETag Value
                    ETag = RestFrameworkUtils.getFinalETag();

                    // Test the ETag
                    if (String.isNotBlank(ETagRequest) && String.isNotBlank(ETag) && ETagRequest == ETag) {

                        // Throw not modified
                        throw new NotModifiedException('Resource not modified!');

                    }

                }

                // Add results if we reached this point.
                responseMap.put( 'records', resultsMap );

            } else if (httpMethod == 'PUT') {

                // Check that we have Permissions for the SObject
                if (!dsr.isAccessible() || !dsr.isUpdateable()) {

                    throw new ForbiddenException('Required permissions (Read, Update) for '+theApiEndpoint.SObject_API_Name__c+'.SObjectType missing.');

                }

                // Update the record with the PUT

            } else if (httpMethod == 'POST') {

                // Check that we have Permissions for the SObject
                if (!dsr.isAccessible() || !dsr.isCreateable() || !dsr.isUpdateable()) {

                    throw new ForbiddenException('Required permissions (Create, Read, Update) for '+theApiEndpoint.SObject_API_Name__c+'.SObjectType missing.');

                }

                // Insert or Upsert the record(s) from the POST

            } else if (httpMethod == 'PATCH') {

                // Check that we have Permissions for the SObject
                if (!dsr.isAccessible() || !dsr.isUpdateable()) {

                    throw new ForbiddenException('Required permissions (Read, Update) for '+theApiEndpoint.SObject_API_Name__c+'.SObjectType missing.');

                }

                // Update the record with the PATCH

            } else if (httpMethod == 'DELETE') {

                // Check that we have Permissions for the SObject
                if (!dsr.isAccessible() || !dsr.isDeletable()) {

                    throw new ForbiddenException('Required permissions (Read, Delete) for '+theApiEndpoint.SObject_API_Name__c+'.SObjectType missing.');

                }

                // DELETE the record

            } else {

                throw new MethodNotAllowedException( 'HTTP method \'' + httpMethod + '\' not allowed!' );

            }

        } catch (Exception e) {

            // Get Exception Type
            String exceptionType = e.getTypeName();

            // Default status code
            statusCode = 500;

            // Default status and get message
            responseMap = new Map<String, Object> {
                'status' => 'Internal Server Error',
                'error' => e.getMessage()
            };

            // Custom Exception Handling with Status Code
            if (exceptionType == 'RestFrameworkResource.NotModifiedException') {
                statusCode = 304;
                // Not modified should be a blank response
                responseMap = null;
            } else if (exceptionType == 'RestFrameworkResource.BadRequestException') {
                statusCode = 400;
                responseMap.put('status','Bad Request');
            } else if (exceptionType == 'RestFrameworkResource.UnauthorizedException') {
                statusCode = 401;
                responseMap.put('status','Unauthorized');
            } else if (exceptionType == 'RestFrameworkResource.ForbiddenException') {
                statusCode = 403;
                responseMap.put('status','Forbidden');
            } else if (exceptionType == 'RestFrameworkResource.NotFoundException') {
                statusCode = 404;
                responseMap.put('status','Not Found');
            } else if (exceptionType == 'RestFrameworkResource.MethodNotAllowedException') {
                statusCode = 405;
                responseMap.put('status','Method Not Allowed');
            } else if (exceptionType == 'RestFrameworkResource.NotAcceptableException') {
                statusCode = 406;
                responseMap.put('status','Not Acceptable');
            } else if (exceptionType == 'RestFrameworkResource.RequestTimeoutException') {
                statusCode = 408;
                responseMap.put('status','Request Timeout');
            } else if (exceptionType == 'RestFrameworkResource.ConflictException') {
                statusCode = 409;
                responseMap.put('status','Conflict');
            } else if (exceptionType == 'RestFrameworkResource.TooManyRequestsException') {
                statusCode = 429;
                responseMap.put('status','Too Many Requests');
            } else if (exceptionType == 'RestFrameworkResource.NotImplementedException') {
                statusCode = 501;
                responseMap.put('status','Not Implemented');
            } else if (exceptionType == 'RestFrameworkResource.ServiceUnavailableException') {
                statusCode = 503;
                responseMap.put('status', 'Service Unavailable');
            }

            // Remove the error message if it is an Internal Server Error
            if (statusCode == 500) {
                 responseMap.remove('error');
            }

            // Add logging details
            theApiLogEntry.Exception_Message__c = e.getMessage();
            theApiLogEntry.Type_Name__c = e.getTypeName();
            theApiLogEntry.Stack_Trace_String__c = e.getStackTraceString();
        }

        // Add properties to the Log Entry
        theApiLogEntry.Status_Code__c = statusCode;
        theApiLogEntry.Remote_Address__c = req.remoteAddress;
        theApiLogEntry.API_Version__c = theApiVersion != null ? theApiVersion.Id : null;
        theApiLogEntry.API_Endpoint__c = theApiEndpoint != null ? theApiEndpoint.Id : null;
        theApiLogEntry.API_Policies_Applied__c = theAppliedApiPolicies;
        theApiLogEntry.HTTP_Method__c = httpMethod;
        theApiLogEntry.Request_URI__c = JSON.serialize(req.requestURI);
        theApiLogEntry.Request_Params__c = JSON.serialize(req.params);
        theApiLogEntry.Request_Headers__c = JSON.serialize(req.headers);

        // Add the Limits to the Log
        theApiLogEntry.Execution_Governors_and_Limits__c = RestFrameworkUtils.getLimits();

        // Set the request response status code
        res.statusCode = statusCode;

        // Insert the Log entry if we are tracking API Access
        if (theApiVersion != null && theApiVersion.Log_API_Access__c) {
            insert theApiLogEntry;
            theApiLogEntry.recalculateFormulas();

            // Add the logging id to the body if this is an error
            if (statusCode >= 400) {
                responseMap = responseMap == null ? new Map<String, Object>() : responseMap;
                responseMap.put('error-log', 'Error logged. If the error persists please contact support for assistance and quote log Id \''+theApiLogEntry.Name__c+'\'.');
            }

            // Add an API Log Entry Id
            res.addHeader('Log-Entry-Id', theApiLogEntry.Name__c);
        }

        // If we have a response
        if (responseMap != null) {
            // Response object
            Object theResponse;
            // If this is not an exception
            if (statusCode < 300) {
                // Get the results
                List<Object> theResults = (List<Object>) responseMap.get('records');
                // If we have records
                if (theResults != null) {
                    // If this is a detail get
                    if (isDetailGet) {
                        // Add only the detail record
                        theResponse = theResults[0];
                        // Else if this is a list Get
                    } else if (httpMethod == 'GET') {
                        // Set Result Size Header
                        res.addHeader('Result-Size', String.valueOf(theResults.size()));
                        // Set the total size mapping
                        responseMap.put('totalSize', theResults.size());
                        // Add the response
                        theResponse = responseMap;
                    }
                }
            // Else add the exception response
            } else {
                // Remove any records we might have
                responseMap.remove('records');
                // Add the response map
                theResponse = responseMap;
            }
            // Add ETag if we have one
            if (String.isNotBlank(ETag)) {
                res.addHeader('ETag', ETag);
            }
            // Get the response as a string based on the Content Type
            String theResponseStr;
            if (contentType == 'JSON') {
                // Set Content Type
                res.addHeader('Content-Type', 'application/json');
                // Set the String Response
                theResponseStr = JSON.serialize( theResponse );
            } else {
                // Set Content Type
                res.addHeader('Content-Type', 'text/xml');
                // @TODO attributes driven XML Serializer method
                // Set the String Response
                theResponseStr = XmlUtility.serialize( theResponse, theApiEndpoint.Name );
            }
            // Set Content Length as Content Size
            res.addHeader('Content-Size', String.valueOf(theResponseStr.length()));
            // Set the request response body
            res.responseBody = Blob.valueOf(theResponseStr);
        }

        // Add response headers
        if (theApiVersion != null && theApiVersion.Log_API_Access__c) {
            theApiLogEntry.Response_Headers__c = JSON.serialize(res.headers);
            update theApiLogEntry;
        }
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Custom Exception Handling used for 3XX HTTP Response codes - Redirection
    **/
    private class NotModifiedException extends Exception {}         // 304

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Custom Exception Handling used for 4XX HTTP Response codes - Client Errors
    **/
    global class BadRequestException extends Exception {}           // 400
    global class UnauthorizedException extends Exception {}         // 401
    global class ForbiddenException extends Exception {}            // 403
    global class NotFoundException extends Exception {}             // 404
    global class MethodNotAllowedException extends Exception {}     // 405
    global class NotAcceptableException extends Exception {}        // 406
    global class RequestTimeoutException extends Exception {}       // 408
    global class ConflictException extends Exception {}             // 409
    global class TooManyRequestsException extends Exception {}      // 429

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Custom Exception Handling used for 5XX HTTP Response codes - Server Errors
    **/
    global class InternalServerErrorException extends Exception {}  // 500
    global class NotImplementedException extends Exception {}       // 501
    global class ServiceUnavailableException extends Exception {}   // 503
}