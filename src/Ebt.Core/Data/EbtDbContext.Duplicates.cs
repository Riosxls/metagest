using Ebt.Core.Entities;
using Microsoft.EntityFrameworkCore;

namespace Ebt.Core.Data;

public partial class EbtDbContext
{
    public DbSet<DuplicateDismissal> DuplicateDismissals => Set<DuplicateDismissal>();

    partial void ConfigureDuplicates(ModelBuilder b)
    {
        b.Entity<DuplicateDismissal>(e =>
        {
            e.ToTable("duplicate_dismissals", t => t.HasCheckConstraint("ck_duplicate_dismissals_order", "low_id < high_id"));
            e.Property(x => x.Kind).HasMaxLength(20);
            e.Property(x => x.Reason).HasMaxLength(500);
            e.Property(x => x.CreatedBy).HasMaxLength(100);
            e.HasIndex(x => new { x.Kind, x.LowId, x.HighId }).IsUnique();
        });
    }
}
