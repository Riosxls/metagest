namespace Ebt.Core.Entities;

/// <summary>
/// "These two records are not duplicates": the pair stops being flagged. <see cref="Kind"/> is customer, product or supplier;
/// the ids are plain numbers (no foreign keys, so deleting a record never has to touch this row), stored with
/// <see cref="LowId"/> smaller than <see cref="HighId"/> so a pair has one row whichever record was opened.
/// Reference data: the data reset never touches it. Audited (who marked it, and who took it back).
/// </summary>
public class DuplicateDismissal
{
    public int Id { get; set; }
    public required string Kind { get; set; }
    public int LowId { get; set; }
    public int HighId { get; set; }
    public string? Reason { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public string? CreatedBy { get; set; }
}
