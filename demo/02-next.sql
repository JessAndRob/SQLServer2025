CREATE TABLE dbo.Feedback (
    FeedbackId  INT IDENTITY PRIMARY KEY,
    Customer    NVARCHAR(100),
    Comment     NVARCHAR(MAX),
    SubmittedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

CREATE TABLE dbo.Customers (
    CustomerId  INT IDENTITY PRIMARY KEY,
    Name        NVARCHAR(100),
    Email       NVARCHAR(200),
    CreditCard  NVARCHAR(50)   -- the obviously-bad-idea column for dramatic effect
);

INSERT dbo.Customers (Name, Email, CreditCard) VALUES
 ('Alice Smith', 'alice@contoso.com', '4111-1111-1111-1111'),
 ('Bob Jones',   'bob@contoso.com',   '5500-0000-0000-0004');

INSERT dbo.Feedback (Customer, Comment) VALUES
 ('Alice Smith', 'Loved the new release, the performance is great.'),
 ('Bob Jones',   'Documentation could be clearer in places.');

 GO

 CREATE OR ALTER PROCEDURE dbo.SummariseFeedback
AS
BEGIN
    DECLARE @comments NVARCHAR(MAX) =
        (SELECT STRING_AGG(CONCAT('- ', Comment), CHAR(10))
         FROM dbo.Feedback);

    DECLARE @prompt NVARCHAR(MAX) = CONCAT(
        N'You are a helpful assistant summarising customer feedback for a manager. ',
        N'Here is the feedback:', CHAR(10), @comments, CHAR(10),
        N'Provide a short summary.'
    );

    DECLARE @payload NVARCHAR(MAX) = (
        SELECT 'gpt-4o-mini' AS [model],
               JSON_ARRAY(
                   JSON_OBJECT('role':'system','content':'You are a helpful assistant.'),
                   JSON_OBJECT('role':'user',  'content': @prompt)
               ) AS [messages]
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    DECLARE @response NVARCHAR(MAX), @ret INT;
    EXEC @ret = sp_invoke_external_rest_endpoint
        @url        = N'https://your-aoai.openai.azure.com/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-02-01',
        @method     = 'POST',
        @credential = [https://your-aoai.openai.azure.com],
        @payload    = @payload,
        @response   = @response OUTPUT;

    SELECT JSON_VALUE(@response, '$.result.choices[0].message.content') AS Summary;
END