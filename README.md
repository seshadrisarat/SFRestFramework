# Salesforce Custom Rest Framework

This was a small project with custom REST, planned to extend with dynamic JSON but never got around to it.

Install the package:

<br/>

<a href="https://githubsfdeploy.herokuapp.com?owner=tiaanswart&repo=SFRestFramework&ref=master">
  <img alt="Deploy to Salesforce"
       src="https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/deploy.png">
</a>

<br/>
<br/>

The API can handle custom endpoints in custom versions:

`https://<instance>.force.com/services/apexrest/api/v1/Accounts`

`https://<instance>.force.com/services/apexrest/api/v2/Accounts`

The API can handle Id's with children custom endpoints:

`https://<instance>.force.com/services/apexrest/api/v1/Accounts/<Id>`

`https://<instance>.force.com/services/apexrest/api/v2/Accounts/<Id>/Contacts`

The API supports the following HTTP Methods:

1. `GET`
1. `HEAD`
1. `POST`
1. `PUT`
1. `PATCH`
1. `DELETE`

The API has Log Entries to monitor the requests and keep an eye on Limits etc.

The API supports applying policies to API requests, like:

1. Apply limits by IP Range
1. Apply Hour Range limits (for example, only allow API calls from 8am to 5pm)
1. Apply limits by HTTP Method
1. Apply actual access count limits by `hour`, `day`, `month` or `year`

The API supports `XML` and `JSON` response types and receiving body.

The API supports adding an `ETAG` for If-Not-Modified responses

The API supports custom exception responses and HTTP Response Codes:

1. `NotModifiedException`          - `304`
1. `BadRequestException`           - `400`
1. `UnauthorizedException`         - `401`
1. `ForbiddenException`            - `403`
1. `NotFoundException`             - `404`
1. `MethodNotAllowedException`     - `405`
1. `TooManyRequestsException`      - `429`
1. `ServiceUnavailableException`   - `503`

### Future plans:

1. Dynamic structure with custom key value pairs
1. Dynamically generate API documentation
1. Support more than two level deep Parent and Child relationships