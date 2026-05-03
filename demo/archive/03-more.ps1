function Get-FeedbackSummary {
    Invoke-DbaQuery -SqlInstance 'localhost' -Database 'AIDemo' `
        -Query 'EXEC dbo.SummariseFeedback' |
        Select-Object -ExpandProperty Summary
}

Get-FeedbackSummary
# "Customers are happy with the new release performance, but suggest documentation improvements."