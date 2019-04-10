/**
* @author Tiaan Swart (tiaan@cloudinit.nz)
* @date 2018-06-16
* @description 
*
* CHANGE LOG
* 2018-06-16 - Initial setup
**/
global with sharing class RestFrameworkUtils {

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get the API Version from it's Name
    *   @return API Version
    **/
    public static API_Version__c getApiVersion(String apiVersion)
    {
        // Find the API version
        List<API_Version__c> theApiVersions = [SELECT Name, Authentication_Required__c, Log_API_Access__c, Active__c,
                                                      Enforce_Access_Limit_Policy__c, Enforce_Restrictive_Time_Policy__c,
                                                      Enforce_Whitelist_Policy__c, Enforce_ETag_Header__c, Allowed_Content_Types__c
                                               FROM API_Version__c
                                               WHERE Name =: apiVersion
                                               LIMIT 1];

        // If we have no API Versions
        if (theApiVersions.isEmpty()) {
            throw new RestFrameworkResource.NotFoundException( 'API version \'' + apiVersion + '\' not found!' );
        }

        // Get the API Version Record
        API_Version__c theApiVersion = theApiVersions[0];

        // Check if the API Version is Active
        if (!theApiVersion.Active__c) {
            throw new RestFrameworkResource.ServiceUnavailableException('API version \''+apiVersion+'\' not active!');
        // If Auth is required Guests can not view the the API
        } else if (UserInfo.getUserType() == 'Guest' && theApiVersion.Authentication_Required__c) {
            throw new RestFrameworkResource.UnauthorizedException('Please log in to access the API.');
        // If we need ETags
        } else if (theApiVersion.Enforce_ETag_Header__c &&
                   (new Set<String>{'GET','HEAD'}).contains(RestFrameworkResource.req.httpMethod) &&
                   (!(RestFrameworkResource.req.headers.containsKey('ETag') || RestFrameworkResource.req.headers.containsKey('If-None-Match')) ||
                   ((RestFrameworkResource.req.headers.containsKey('ETag') && String.isBlank(RestFrameworkResource.req.headers.get('ETag'))) ||
                   (RestFrameworkResource.req.headers.containsKey('If-None-Match') && String.isBlank(RestFrameworkResource.req.headers.get('If-None-Match')))))
        ) {
            throw new RestFrameworkResource.ForbiddenException( 'Required \'ETag\' or \'If-None-Match\' header not found!' );
        }

        return theApiVersion;
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get the API Version from it's Name
    *   @return API Version
    **/
    public static Map<String, API_Endpoint__c> APIEndpointsMapByName = new Map<String, API_Endpoint__c>();
    public static API_Endpoint__c getApiEndpoint(API_Version__c apiVersion, String apiEndpointName)
    {
        // Find the API Endpoints, if we have none
        if (APIEndpointsMapByName.isEmpty()) {
            List<API_Endpoint__c> theApiEndpoints = [SELECT Name, Allowed_Methods__c, SObject_API_Name__c, Version_Endpoint__c, Active__c,
                                                            Label__c, SObject_Id_Field__c, ETag_Datetime_Field__c, API_Parent_Endpoint__c,
                                                            Parent_SObject_Id_Field__c,
                                                            (SELECT Name FROM API_Endpoints__r WHERE Include_In_Parent_GET__c = TRUE),
                                                            (SELECT Id FROM API_Field_Mappings__r)
                                                     FROM API_Endpoint__c
                                                     WHERE API_Version__c =: apiVersion.Id
                                                     LIMIT 50000];
            // If we have API Endpoints
            if (!theApiEndpoints.isEmpty()) {
                // Map them
                for (API_Endpoint__c theApi : theApiEndpoints) {
                    APIEndpointsMapByName.put(theApi.Name, theApi);
                }
            } else {
                throw new RestFrameworkResource.NotFoundException( 'API version \'' + apiVersion + '\' has no API Endpoints!' );
            }
        }

        // Get the API Endpoint
        API_Endpoint__c theEndpoint = APIEndpointsMapByName.get(apiEndpointName);

        String apiExceptionPretext = 'API Endpoint \''+apiEndpointName+'\' for API Version \''+apiVersion.Name+'\' ';

        // If we have no Endpoint
        if (theEndpoint == null) {
            throw new RestFrameworkResource.NotFoundException( apiExceptionPretext + 'not found!' );
        // If the Endpoint is Active
        } else if (!theEndpoint.Active__c) {
            throw new RestFrameworkResource.ServiceUnavailableException(  apiExceptionPretext + 'not active!' );
        // If we are allowed to access this Endpoint through the HTTP Method
        } else if (!theEndpoint.Allowed_Methods__c.contains(RestFrameworkResource.req.httpMethod)) {
            throw new RestFrameworkResource.MethodNotAllowedException(  apiExceptionPretext + 'does not allow \''+RestFrameworkResource.req.httpMethod+'\' requests!' );
        }

        // Get the SObject Describe
        DescribeSObjectResult dsr = RestFrameworkUtils.getDsr(theEndpoint.SObject_API_Name__c);

        // Check that we have Permissions for the SObject
        if (!dsr.isAccessible()) {
            throw new RestFrameworkResource.ForbiddenException('Required permission (IsAccessible) for SObjectType \''+theEndpoint.SObject_API_Name__c+'\' missing.');
        }

        return theEndpoint;
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get the Access Count of the Current User based on Params, only successful access counts.
    *   @return Integer access count
    **/
    @TestVisible
    private static Integer getAccessCount(String httpMethod, String remoteAddress, Id theApiVersionId, Id theApiEndpointId, Datetime startDatetime)
    {
        Id userId = UserInfo.getUserId();
        return Database.countQuery('SELECT count() ' +
                'FROM API_Log_Entry__c ' +
                'WHERE API_Version__c =: theApiVersionId ' +
                (String.isNotBlank(theApiEndpointId) ? 'AND API_Endpoint__c =: theApiEndpointId ' : '') +
                'AND ' + (UserInfo.getUserType() == 'Guest' ? 'Remote_Address__c =: remoteAddress' : '(CreatedById =: userId OR Remote_Address__c =: remoteAddress)') + ' ' +
                'AND HTTP_Method__c =: httpMethod ' +
                'AND Status_Code__c < 400 AND (CreatedDate >= :startDatetime AND CreatedDate < TOMORROW)');
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get the Access Count of the Current User based on Params, and compare against the passed limit
    *                Add remaining Limit Header or throw Exception
    **/
    public static void checkAccessCount(Id theApiVersionId, Id theApiEndpointId, Datetime startDatetime,
            Decimal accessLimit, String limitDescription)
    {
        // Get the Access Count
        Integer accessCount = getAccessCount(
            RestFrameworkResource.req.httpMethod,
            RestFrameworkResource.req.remoteAddress,
            theApiVersionId,
            theApiEndpointId,
            startDatetime
        );

        // And we have passed the limit
        if (accessLimit < accessCount) {

            throw new RestFrameworkResource.TooManyRequestsException(
                String.format(
                    'Access not allowed! {0} {1} access limit of {2} exceeded: {3}.',
                    new String[] {
                        RestFrameworkResource.req.httpMethod,
                        limitDescription,
                        String.valueOf(accessLimit),
                        String.valueOf(accessCount)
                    }
                )
            );

        }

        // Add Remaining Access Limit Header
        RestFrameworkResource.res.addHeader('Remaining-Access-Limit-'+limitDescription, String.valueOf(accessLimit - accessCount - 1));
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get the DescribeSObjectResult and store it in a Map for Caching
    *   @return DescribeSObjectResult
    **/
    private static Map<String, DescribeSObjectResult> dsrBySObjectName = new Map<String, DescribeSObjectResult>();
    public static DescribeSObjectResult getDsr(String SObjectTypeName)
    {
        // If we have the cached value
        if (dsrBySObjectName != null && dsrBySObjectName.containsKey(SObjectTypeName)) {
            return dsrBySObjectName.get(SObjectTypeName);
        }
        // Else get the Global describe
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        if (!gd.containsKey(SObjectTypeName)) {
            throw new RestFrameworkResource.NotFoundException( 'SObjectType \''+SObjectTypeName+'\' not found!' );
        }
        // Get the dsr and add it to the cache
        dsrBySObjectName.put(SObjectTypeName, gd.get(SObjectTypeName).getDescribe());
        return dsrBySObjectName.get(SObjectTypeName);
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get the Fields for an SObject and store it in a Map for Caching
    *   @return List of string Fields
    **/
    public static Map<String, Map<String, SObjectField>> fieldsBySObjectName = new Map<String, Map<String, SObjectField>>();
    public static List<String> getSObjectFieldsList(String SObjectTypeName)
    {
        // If we have the cached value
        if (fieldsBySObjectName != null && fieldsBySObjectName.containsKey(SObjectTypeName)) {
            return new List<String>(fieldsBySObjectName.get(SObjectTypeName).keySet());
        }
        // Get the dsr
        DescribeSObjectResult dsr = getDsr(SObjectTypeName);
        // Get the fields and add it to the cache
        fieldsBySObjectName.put(SObjectTypeName, dsr.fields.getMap());
        return new List<String>(fieldsBySObjectName.get(SObjectTypeName).keySet());
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get the Field for an SObject
    *   @return SObjectField
    **/
    public static SObjectField getSObjectField(String SObjectTypeName, String SObjectFieldName)
    {
        // If we have the cached value
        if (fieldsBySObjectName != null && !fieldsBySObjectName.get(SObjectTypeName).containsKey(SObjectFieldName)) {
            throw new RestFrameworkResource.NotFoundException( 'SObjectField \''+SObjectFieldName+'\' for SObjectType \''+SObjectTypeName+'\' not found!' );
        }
        return fieldsBySObjectName.get(SObjectTypeName).get(SObjectFieldName);
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Build a Query with specified params
    *   @return List of SObjects
    **/
    public static String buildSOQL(List<String> fields, String sObjectName, String idField, String recordId, String customCondition)
    {
        // Select using all the fields
        return String.format(
                'SELECT {0} FROM {1}{2}{3}{4}{5}{6}{7}{8}',
                new String[] {
                        String.join(fields, ','),
                        sObjectName,
                        (String.isNotBlank(idField) || String.isNotBlank(recordId)) || String.isNotBlank(customCondition) ? ' WHERE ' : '',
                        String.isNotBlank(idField) ? idField : '',
                        String.isNotBlank(idField) ? (String.isNotBlank(recordId) ? '=' : '!=') : '',
                        String.isNotBlank(idField) ? (String.isNotBlank(recordId) ? '\''+recordId+'\'' : 'NULL') : '',
                        String.isNotBlank(idField) && String.isNotBlank(customCondition) ? ' AND (' : '',
                        String.isNotBlank(customCondition) ? customCondition : '',
                        String.isNotBlank(idField) && String.isNotBlank(customCondition) ? ')' : ''
                }
        );
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get the Records for a GET or HEAD request
    *   @return List of SObjects
    **/
    public static List<SObject> getResults(List<String> fields, String sObjectName, String idField, String recordId,
            String customCondition)
    {
        // Get results
        List<SObject> results = Database.query( buildSOQL(fields, sObjectName, idField, recordId, customCondition) );

        // If we had an Id we expect a result
        if (String.isNotBlank(recordId) && results.isEmpty()) {

            throw new RestFrameworkResource.NotFoundException('Record with Id \''+recordId+'\' Not Found!');

        }

        // Return the results
        return results;
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get an Epoc Long from a Datetime object
    *   @return Epoc Long String
    **/
    public static String getEpocLongStr(Object dateTimeObj)
    {
        return String.valueOf(((DateTime) JSON.deserialize((String) dateTimeObj, DateTime.class)).getTime());
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get an ETag value from passed value
    *   @return String MD5 ETag
    **/
    private static String etagKey = 'hgdhdhhdjfh12ehsn';
    private static String etagSecret = 'DNf32sdsj747dhkjd8893jjjdjds7jjk';
    public static String getETagVal(String etagValue)
    {
        return EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf(etagKey + etagSecret + etagValue)));
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Build an attributes map for a record
    **/
    public static void buildAttributesMappings(Map<String, Object> recordMap, API_Endpoint__c theApiEndpoint, List<String> childETags)
    {
        // Add the attributes mapping
        recordMap.put(
            'attributes',
            new Map<String, String>{
                'type' => theApiEndpoint.Label__c,
                'url' => theApiEndpoint.Version_Endpoint__c + String.valueOf(recordMap.get(theApiEndpoint.SObject_Id_Field__c)),
                'etag' => getETagVal(
                    getEpocLongStr(recordMap.get(theApiEndpoint.ETag_Datetime_Field__c))
                    + String.join(childETags, '')
                )
            }
        );
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description String Final Etag, Prepared by the Build Record Map
    **/
    private static String finalEtag = '';

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Build the record map with attributes and custom mappings
    **/
    public static void buildRecordMap(List<Object> resultsMap, API_Endpoint__c theApiEndpoint, Map<String, API_Endpoint__c> childRelationshipMap,
            Boolean isChildEndpoint)
    {
        // For each record
        for (Object record : resultsMap) {

            // Get the record as a Map
            Map<String, Object> recordMap = (Map<String, Object>) record;

            // List to keep the Child ETags
            List<String> childETags = new List<String>();

            // If we have child relationships they need to be built as well
            for (String childRelationshipName : childRelationshipMap.keySet()) {

                // Get the Endpoint
                API_Endpoint__c childEndpoint = childRelationshipMap.get(childRelationshipName);

                // Get the Child Records Map
                Map<String, Object> childRecordsMap = (Map<String, Object>) recordMap.get(childRelationshipName);

                // Remove the "done" key value pair
                childRecordsMap.remove('done');

                // Get the records
                List<Object> childRecords = (List<Object>) childRecordsMap.get('records');

                // Now build the record Map from the actual records
                buildRecordMap(childRecords, childEndpoint, new Map<String, API_Endpoint__c>(), true);

                // Gather the ETags
                for (Object childRecord : childRecords) {

                    // Get the attributes mapping
                    Map<String, String> attributesMapping = (Map<String, String>) ((Map<String, Object>) childRecord).get('attributes');

                    // Add the ETag
                    childETags.add(attributesMapping.get('etag'));

                }

                // Replace Child Relationship Name with Endpoint Name
                recordMap.put(childEndpoint.Name, recordMap.get(childRelationshipName));

                // If the Child Relationship name is different to the Child Endpoint name
                if (childEndpoint.Name != childRelationshipName)  {
                    // Remove it
                    recordMap.remove(childRelationshipName);
                }

            }

            // Add the attributes mapping
            buildAttributesMappings(recordMap, theApiEndpoint, childETags);

            // If this is not a child endpoint
            if (!isChildEndpoint) {

                // Get the attributes mapping
                Map<String, String> attributesMapping = (Map<String, String>) ((Map<String, Object>) recordMap).get('attributes');

                // Add the ETag
                finalEtag += (String.isBlank(finalEtag) ? '' : ',') + attributesMapping.get('etag');
            }

        }
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get a combination of all etags generated as a final etag
    *   @return String MD5 ETag
    **/
    public static String getFinalETag()
    {
        // Get a list of ETags
        if (String.isNotBlank(finalEtag)) {
            List<String> etagList = finalEtag.split(',');
            // If we only have one etag
            if (etagList.size() == 1) {
                // Return that one
                return etagList[0];
            }
            // Else create a combination ETag
            return getETagVal( String.join(etagList, '') );
        }
        return null;
    }

    /**
    *   @author Tiaan Swart (tiaan@cloudinit.nz)
    *   @description Get a String output of Execution Governors and Limits
    *   @return String of Limits used
    **/
    public static String getLimits()
    {
        return  'AggregateQueries: ' + Limits.getAggregateQueries() + ' / ' + Limits.getLimitAggregateQueries() + ((Limits.getAggregateQueries()/Limits.getLimitAggregateQueries()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'Callouts: ' + Limits.getCallouts() + ' / ' + Limits.getLimitCallouts() + ((Limits.getCallouts()/Limits.getLimitCallouts()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'CpuTime: ' + Limits.getCpuTime() + ' / ' + Limits.getLimitCpuTime() + ((Limits.getCpuTime()/Limits.getLimitCpuTime()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'DatabaseTime: ' + Limits.getDatabaseTime() + ' / ' + Limits.getLimitDatabaseTime() + '\n' +
                'DmlRows: ' + Limits.getDmlRows() + ' / ' + Limits.getLimitDmlRows() + ((Limits.getDmlRows()/Limits.getLimitDmlRows()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'DmlStatements: ' + Limits.getDmlStatements() + ' / ' + Limits.getLimitDmlStatements() + ((Limits.getDmlStatements()/Limits.getLimitDmlStatements()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'EmailInvocations: ' + Limits.getEmailInvocations() + ' / ' + Limits.getLimitEmailInvocations() + ((Limits.getEmailInvocations()/Limits.getLimitEmailInvocations()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'FindSimilarCalls: ' + Limits.getFindSimilarCalls() + ' / ' + Limits.getLimitFindSimilarCalls() + ((Limits.getFindSimilarCalls()/Limits.getLimitFindSimilarCalls()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'FutureCalls: ' + Limits.getFutureCalls() + ' / ' + Limits.getLimitFutureCalls() + ((Limits.getFutureCalls()/Limits.getLimitFutureCalls()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'HeapSize: ' + Limits.getHeapSize() + ' / ' + Limits.getLimitHeapSize() + ((Limits.getHeapSize()/Limits.getLimitHeapSize()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'MobilePushApexCalls: ' + Limits.getMobilePushApexCalls() + ' / ' + Limits.getLimitMobilePushApexCalls() + ((Limits.getMobilePushApexCalls()/Limits.getLimitMobilePushApexCalls()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'Queries: ' + Limits.getQueries() + ' / ' + Limits.getLimitQueries() + ((Limits.getQueries()/Limits.getLimitQueries()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'QueryLocatorRows: ' + Limits.getQueryLocatorRows() + ' / ' + Limits.getLimitQueryLocatorRows() + ((Limits.getQueryLocatorRows()/Limits.getLimitQueryLocatorRows()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'QueryRows: ' + Limits.getQueryRows() + ' / ' + Limits.getLimitQueryRows() + ((Limits.getQueryRows()/Limits.getLimitQueryRows()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'QueueableJobs: ' + Limits.getQueueableJobs() + ' / ' + Limits.getLimitQueueableJobs() + ((Limits.getQueueableJobs()/Limits.getLimitQueueableJobs()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'RunAs: ' + Limits.getRunAs() + ' / ' + Limits.getLimitRunAs() + ((Limits.getRunAs()/Limits.getLimitRunAs()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'SavepointRollbacks: ' + Limits.getSavepointRollbacks() + ' / ' + Limits.getLimitSavepointRollbacks() + ((Limits.getSavepointRollbacks()/Limits.getLimitSavepointRollbacks()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'Savepoints: ' + Limits.getSavepoints() + ' / ' + Limits.getLimitSavepoints() + ((Limits.getSavepoints()/Limits.getLimitSavepoints()) > 0.5 ? ' *** Close to limit *** ' : '') + '\n' +
                'SoslQueries: ' + Limits.getSoslQueries() + ' / ' + Limits.getLimitSoslQueries() + ((Limits.getSoslQueries()/Limits.getLimitSoslQueries()) > 0.5 ? ' *** Close to limit *** ' : '');
    }

}